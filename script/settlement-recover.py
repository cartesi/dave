#!/usr/bin/env python3
"""Prepare and simulate a Dave recovery transaction from independently verified evidence."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("settlement_watch", Path(__file__).with_name("settlement-watch.py"))
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

STAGE = "stageTournamentResult(uint256,((bytes32,bytes32[]),(bytes32,bytes32[]),(bytes32,bytes32[])))"
ACCEPT = "acceptStagedTournamentResult(uint256)"


def hash32(value):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
        raise ValueError("expected a 32-byte hash")
    return value.lower()


def proof_argument(proof, outputs_root):
    leaves = []
    for name in ("iflags_y", "htif_tohost", "tx_buffer"):
        leaf = proof[name]
        block = hash32(leaf["data_block"])
        siblings = leaf["siblings"]
        if not isinstance(siblings, list):
            raise ValueError("proof siblings must be a list")
        hashes = ",".join(hash32(item) for item in siblings)
        leaves.append(f"({block},[{hashes}])")
    if hash32(proof["tx_buffer"]["data_block"]) != outputs_root:
        raise ValueError("proof outputs root differs from verified outputs root")
    return "(" + ",".join(leaves) + ")"


def prepare(rpc, expected, action, sender, max_head_age):
    chain = expected["chain_id"]
    epoch = expected["epoch"]
    if type(chain) is not int or chain < 1 or type(epoch) is not int or epoch < 0:
        raise ValueError("evidence requires integer chain_id and epoch")
    for value in (expected["consensus"], expected["app"], sender):
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
            raise ValueError("invalid evidence or sender address")
    current = watch.snapshot(rpc, expected["consensus"], chain, "latest", max_head_age)
    if current["app"] != expected["app"].lower() or current["epoch"] != epoch:
        raise ValueError("deployment or epoch changed; obtain new verified evidence")
    commitment = hash32(expected["commitment"])
    final_state = hash32(expected["final_state"])
    outputs_root = hash32(expected["outputs_root"])
    if current["winner"] != commitment or current["winner_state"] != final_state:
        raise ValueError("winning result differs from independently verified evidence")
    if action == "stage":
        if current["phase"] != "winner_unstaged":
            raise ValueError(f"staging is not available: {current['phase']}")
        signature, arguments = STAGE, [str(epoch), proof_argument(expected["proof"], outputs_root)]
    else:
        if current["phase"] != "acceptance_ready":
            raise ValueError(f"acceptance is not available: {current['phase']}")
        if current["staged_state"] != final_state or current["staged_outputs"] != outputs_root:
            raise ValueError("staged result differs from independently verified evidence")
        signature, arguments = ACCEPT, [str(epoch)]
    calldata = subprocess.check_output(["cast", "calldata", signature, *arguments], text=True).strip()
    transaction = dict(to=expected["consensus"].lower(), **{"from": sender.lower()}, data=calldata, value="0x0")
    # Simulate at the exact observed head. Epoch arguments prevent advancing a later epoch.
    result = rpc("eth_call", [transaction, hex(current["block"])])
    if result != "0x":
        raise ValueError("unexpected settlement simulation return data")
    head = rpc("eth_getBlockByNumber", [hex(current["block"]), False])
    if head["hash"] != current["block_hash"]:
        raise ValueError("head changed during recovery preparation")
    return dict(verdict="simulated", action=action, chain_id=chain, epoch=epoch,
                observed_block=current["block"], observed_block_hash=current["block_hash"],
                transaction=transaction)


def export_evidence(state_dir, epoch):
    # Export one consistent read-only SQLite snapshot; this does not perform replay.
    database = (state_dir / "db.sqlite3").resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(database, uri=True) as connection:
        connection.execute("BEGIN")
        chain, app, consensus = connection.execute(
            "SELECT chain_id, app, consensus FROM sling_config WHERE id = 0").fetchone()
        row = connection.execute(
            "SELECT computation_hash, final_state, iflags_y_data_block, iflags_y_siblings, "
            "htif_tohost_data_block, htif_tohost_siblings, tx_buffer_data_block, tx_buffer_siblings "
            "FROM settlement_info WHERE epoch_number = ?", (epoch,)).fetchone()
        if row is None:
            raise ValueError("epoch has no computed settlement material")
    def leaf(block, siblings):
        if len(block) != 32 or len(siblings) != 59 * 32:
            raise ValueError("stored machine proof has an unsupported layout")
        return dict(data_block="0x" + block.hex(),
                    siblings=["0x" + siblings[i:i + 32].hex() for i in range(0, len(siblings), 32)])
    return dict(chain_id=chain, app="0x" + app.hex(), consensus="0x" + consensus.hex(), epoch=epoch,
                commitment="0x" + row[0].hex(), final_state="0x" + row[1].hex(), outputs_root="0x" + row[6].hex(),
                proof=dict(iflags_y=leaf(row[2], row[3]), htif_tohost=leaf(row[4], row[5]),
                           tx_buffer=leaf(row[6], row[7])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--action", required=True, choices=["export", "stage", "accept"])
    parser.add_argument("--from", dest="sender")
    parser.add_argument("--state-dir", type=Path, help="Verified replay directory to export")
    parser.add_argument("--epoch", type=int)
    parser.add_argument("--max-head-age-seconds", type=int, default=1800)
    args = parser.parse_args()
    try:
        if args.action == "export":
            if args.state_dir is None or args.epoch is None or args.epoch < 0:
                raise ValueError("export requires --state-dir and nonnegative --epoch")
            print(json.dumps(export_evidence(args.state_dir, args.epoch), sort_keys=True))
            return 0
        if not args.rpc_url or not args.evidence or not args.sender:
            raise ValueError("stage/accept require --rpc-url, --evidence and --from")
        expected = json.loads(args.evidence.read_text())
        result = prepare(watch.Rpc(args.rpc_url), expected, args.action, args.sender, args.max_head_age_seconds)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Exception as error:
        print(json.dumps(dict(verdict="recovery_refused", error=str(error))))
        return 1


if __name__ == "__main__":
    sys.exit(main())
