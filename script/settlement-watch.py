#!/usr/bin/env python3
"""Read-only Dave settlement observer. Never signs or submits transactions."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request


class Rpc:
    def __init__(self, url):
        self.url = url

    def __call__(self, method, params):
        payload = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode()
        request = urllib.request.Request(self.url, payload, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)
        if "error" in result:
            raise ValueError(f"{method}: {result['error']}")
        return result["result"]


def words(value, count):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value) or len(value) != 2 + 64 * count:
        raise ValueError(f"expected {count} static ABI words")
    return [int(value[i:i + 64], 16) for i in range(2, len(value), 64)]


def boolean(value):
    if value not in (0, 1):
        raise ValueError("invalid ABI bool")
    return bool(value)


def address(value):
    if not 0 < value < 2**160:
        raise ValueError("invalid contract address")
    return f"0x{value:040x}"


def snapshot(rpc, consensus, chain_id, block_tag, max_head_age):
    if int(rpc("eth_chainId", []), 16) != chain_id:
        raise ValueError("RPC chain id differs from configured chain")
    head = rpc("eth_getBlockByNumber", [block_tag, False])
    number = int(head["number"], 16)
    timestamp = int(head["timestamp"], 16)
    if not 0 <= time.time() - timestamp <= max_head_age:
        raise ValueError("RPC head timestamp is stale or in the future")
    # Every view reads exactly the same block. Verify its hash again afterwards.
    block = hex(number)

    def call(target, signature, count):
        selector = subprocess.check_output(["cast", "sig", signature], text=True).strip()
        return words(rpc("eth_call", [{"to": target, "data": selector}, block]), count)

    app = address(call(consensus, "getApplicationContract()", 1)[0])
    epoch = call(consensus, "getCurrentSealedEpoch()", 8)
    stage = call(consensus, "canStageTournamentResult()", 6)
    accept = call(consensus, "canAcceptStagedTournamentResult()", 6)
    foreclosed = boolean(call(app, "isForeclosed()", 1)[0])
    if stage[3] != epoch[0] or accept[3] != epoch[0]:
        raise ValueError("inconsistent epoch views")
    staged = boolean(epoch[4])
    if boolean(stage[2]) != staged or boolean(accept[0]) != staged:
        raise ValueError("inconsistent staging views")
    if staged and (epoch[6], epoch[7]) != (accept[4], accept[5]):
        raise ValueError("inconsistent staged hashes")
    if foreclosed:
        phase = "foreclosed"
    elif staged:
        phase = "acceptance_ready" if boolean(accept[1]) or boolean(accept[2]) else "staging_wait"
    elif boolean(stage[1]):
        phase = "root_failed"
    elif boolean(stage[0]):
        phase = "winner_unstaged"
    else:
        phase = "tournament_in_progress"
    if rpc("eth_getBlockByNumber", [block, False])["hash"] != head["hash"]:
        raise ValueError("head changed during observation")
    return dict(chain_id=chain_id, consensus=consensus.lower(), app=app, block=number,
                block_hash=head["hash"], head_timestamp=timestamp, epoch=epoch[0], phase=phase,
                winner=f"0x{stage[4]:064x}", winner_state=f"0x{stage[5]:064x}", staged_state=f"0x{epoch[6]:064x}", staged_outputs=f"0x{epoch[7]:064x}")


def observe(current, previous, grace):
    identity = ("chain_id", "consensus", "app")
    if previous and any(current[k] != previous[k] for k in identity):
        raise ValueError("state file belongs to another deployment")
    if previous and (current["block"] < previous["block"] or
                     (current["block"] == previous["block"] and current["block_hash"] != previous["block_hash"])):
        raise ValueError("observation head regressed or changed hash")
    condition = [current[k] for k in ("epoch", "phase", "winner", "staged_state")]
    since = previous["since_block"] if previous and previous["condition"] == condition else current["block"]
    elapsed = current["block"] - since
    blocked = current["phase"] in ("winner_unstaged", "acceptance_ready")
    verdict = "stalled" if blocked and elapsed >= grace else "pending" if blocked else "waiting"
    if current["phase"] == "root_failed":
        verdict = "investigate_root_failure"
    if current["phase"] == "foreclosed":
        verdict = "foreclosed"
    return dict(current, condition=condition, since_block=since, elapsed_blocks=elapsed,
                verdict=verdict, observed_at=int(time.time()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--consensus", required=True)
    parser.add_argument("--chain-id", required=True, type=int)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--grace-blocks", required=True, type=int)
    parser.add_argument("--block", choices=["latest", "safe", "finalized"], default="finalized")
    parser.add_argument("--max-head-age-seconds", type=int, default=1800)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"0x[0-9a-fA-F]{40}", args.consensus) or args.grace_blocks < 1 or args.max_head_age_seconds < 1:
            raise ValueError("invalid address, grace, or head-age limit")
        # One process owns a state file. A timer may not overlap invocations.
        import fcntl
        args.state_file.parent.mkdir(parents=True, exist_ok=True)
        with open(str(args.state_file) + ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            previous = json.loads(args.state_file.read_text()) if args.state_file.exists() else None
            current = snapshot(Rpc(args.rpc_url), args.consensus, args.chain_id, args.block, args.max_head_age_seconds)
            result = observe(current, previous, args.grace_blocks)
            with tempfile.NamedTemporaryFile(mode="w", dir=args.state_file.parent, delete=False) as output:
                json.dump(result, output)
                temporary = output.name
            os.replace(temporary, args.state_file)
        print(json.dumps(result, sort_keys=True))
        return 2 if result["verdict"] == "stalled" else 3 if result["verdict"] == "investigate_root_failure" else 0
    except Exception as error:
        print(json.dumps(dict(verdict="observation_error", chain_id=args.chain_id, consensus=args.consensus,
                                   observed_at=int(time.time()), error=str(error))))
        return 1


if __name__ == "__main__":
    sys.exit(main())
