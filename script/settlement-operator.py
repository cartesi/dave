#!/usr/bin/env python3
"""Check settlement, then offer verified recovery with explicit operator confirmation."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("settlement_recover", Path(__file__).with_name("settlement-recover.py"))
recover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recover)


def confirmed(message):
    try:
        print(message + " [yes/NO] ", file=sys.stderr, end="", flush=True)
        return input().strip().lower() == "yes"
    except EOFError:
        return False


def operate(report, args):
    print(json.dumps(report, sort_keys=True))
    if report["verdict"] != "stalled":
        return 3 if report["verdict"] == "investigate_root_failure" else 0
    action = {"winner_unstaged": "stage", "acceptance_ready": "accept"}[report["phase"]]
    if not confirmed(f"Settlement is stalled at epoch {report['epoch']}. Prepare {action} recovery?"):
        return 2
    if not args.evidence or not args.sender:
        print("Recovery requires --evidence from independent verification and --from.")
        return 2
    expected = json.loads(args.evidence.read_text())
    if expected["consensus"].lower() != args.consensus.lower() or expected["chain_id"] != args.chain_id or expected["epoch"] != report["epoch"]:
        raise ValueError("recovery evidence belongs to another watched deployment")
    rpc = recover.watch.Rpc(args.rpc_url)
    plan = recover.prepare(rpc, expected, action, args.sender, args.max_head_age_seconds)
    print(json.dumps(plan, sort_keys=True))
    if not args.account and not args.unlocked:
        print("Simulation passed. No signer configured; transaction prepared only.")
        return 0
    if not confirmed("Submit this simulated transaction using the configured signer?"):
        return 2
    # The operator may have spent time reviewing. Check and simulate again now.
    fresh = recover.prepare(rpc, expected, action, args.sender, args.max_head_age_seconds)
    if fresh["transaction"] != plan["transaction"]:
        raise ValueError("transaction changed during operator review")
    tx = fresh["transaction"]
    command = ["cast", "send", "--async", "--rpc-url", args.rpc_url,
               "--from", args.sender, tx["to"], tx["data"]]
    command += ["--account", args.account] if args.account else ["--unlocked"]
    try:
        sent = subprocess.run(command, text=True, stdout=subprocess.PIPE, check=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"cast send failed with exit {error.returncode}; inspect its diagnostic") from error
    print(json.dumps(dict(verdict="submitted", action=action, epoch=expected["epoch"],
                          transaction_hash=sent.stdout.strip())))
    print("Submission is not confirmation. Verify the receipt and next EpochSealed before closing the incident.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--consensus", required=True)
    parser.add_argument("--chain-id", required=True, type=int)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--grace-blocks", required=True, type=int)
    parser.add_argument("--max-head-age-seconds", type=int, default=1800)
    parser.add_argument("--block", choices=["latest", "safe", "finalized"], default="finalized")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--from", dest="sender")
    signer = parser.add_mutually_exclusive_group()
    signer.add_argument("--account", help="Foundry keystore account name")
    signer.add_argument("--unlocked", action="store_true", help="Explicitly use an RPC-managed signer (local devnet)")
    args = parser.parse_args()
    try:
        command = [sys.executable, str(Path(__file__).with_name("settlement-watch.py"))]
        for flag, value in [("rpc-url", args.rpc_url), ("consensus", args.consensus), ("chain-id", args.chain_id),
                            ("state-file", args.state_file), ("grace-blocks", args.grace_blocks),
                            ("max-head-age-seconds", args.max_head_age_seconds), ("block", args.block)]:
            command += ["--" + flag, str(value)]
        observed = subprocess.run(command, text=True, stdout=subprocess.PIPE, check=False)
        report = json.loads(observed.stdout)
        if observed.returncode not in (0, 2, 3):
            print(json.dumps(report, sort_keys=True))
            return 1
        return operate(report, args)
    except Exception as error:
        print(json.dumps(dict(verdict="operator_action_failed", error=str(error))))
        return 1


if __name__ == "__main__":
    sys.exit(main())
