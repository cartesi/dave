#!/usr/bin/env python3
"""Observer semantics; real RPC/ABI composition is exercised by the node harness."""
import contextlib
import io
import json
import sys
import tempfile
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("watch", Path(__file__).resolve().parents[1] / "settlement-watch.py")
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def current(phase="winner_unstaged", block=100, epoch=0):
    return dict(chain_id=31337, consensus="0x" + "1" * 40, app="0x" + "2" * 40,
                epoch=epoch, block=block, block_hash=hex(block), phase=phase,
                winner="0x01", staged_state="0x00")


class ObserverTests(unittest.TestCase):
    def test_grace_boundary_and_repeated_same_head(self):
        first = watch.observe(current(), None, 4)
        self.assertEqual(first["verdict"], "pending")
        self.assertEqual(watch.observe(current(), first, 4)["elapsed_blocks"], 0)
        self.assertEqual(watch.observe(current(block=103), first, 4)["verdict"], "pending")
        self.assertEqual(watch.observe(current(block=104), first, 4)["verdict"], "stalled")

    def test_eligibility_starts_a_new_grace_after_staging_wait(self):
        waiting = watch.observe(current("staging_wait"), None, 4)
        ready = watch.observe(current("acceptance_ready", 1000), waiting, 4)
        self.assertEqual(ready["since_block"], 1000)
        self.assertEqual(ready["verdict"], "pending")
        self.assertEqual(watch.observe(current("acceptance_ready", 1004), ready, 4)["verdict"], "stalled")

    def test_changed_epoch_and_winner_reset_condition(self):
        previous = watch.observe(current(), None, 4)
        self.assertEqual(watch.observe(current(block=1000, epoch=1), previous, 4)["verdict"], "pending")
        changed = dict(current(block=1000), winner="0x02")
        self.assertEqual(watch.observe(changed, previous, 4)["verdict"], "pending")

    def test_waiting_failure_and_foreclosure_are_distinct(self):
        for phase, expected in [("tournament_in_progress", "waiting"), ("staging_wait", "waiting"),
                                ("root_failed", "investigate_root_failure"), ("foreclosed", "foreclosed")]:
            previous = watch.observe(current(phase), None, 4)
            self.assertEqual(watch.observe(current(phase, 1000), previous, 4)["verdict"], expected)

    def test_wrong_deployment_and_regression_are_errors(self):
        previous = watch.observe(current(), None, 4)
        for altered in [dict(current(), chain_id=1), current(block=99), dict(current(), block_hash="0xffff")]:
            with self.assertRaises(ValueError):
                watch.observe(altered, previous, 4)

    def test_bad_abi_fails_instead_of_reporting_waiting(self):
        for raw in ["0x", "0xzz", "0x" + "0" * 63]:
            with self.assertRaises(ValueError):
                watch.words(raw, 1)
        with self.assertRaises(ValueError):
            watch.boolean(2)

    def test_rpc_error_and_wrong_chain_propagate(self):
        def failed(*_):
            raise RuntimeError("RPC unavailable")
        with self.assertRaises(RuntimeError):
            watch.snapshot(failed, "0x" + "1" * 40, 31337, "finalized", 1800)
        with self.assertRaisesRegex(ValueError, "chain id"):
            watch.snapshot(lambda *_: "0x1", "0x" + "1" * 40, 31337, "finalized", 1800)

    def test_observation_error_preserves_the_last_successful_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            previous = json.dumps(watch.observe(current(), None, 4))
            state.write_text(previous)
            args = ["observer", "--rpc-url", "http://unused", "--consensus", "0x" + "1" * 40,
                    "--chain-id", "31337", "--state-file", str(state), "--grace-blocks", "4"]
            output = io.StringIO()
            with patch.object(sys, "argv", args), patch.object(watch, "snapshot", side_effect=RuntimeError("RPC down")):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(watch.main(), 1)
            self.assertEqual(json.loads(output.getvalue())["verdict"], "observation_error")
            self.assertEqual(state.read_text(), previous)

    def test_stale_or_future_head_is_not_a_healthy_observation(self):
        for timestamp in [0, 1001]:
            def rpc(method, _):
                return "0x7a69" if method == "eth_chainId" else {"number": "0x64", "timestamp": hex(timestamp)}
            with patch.object(watch.time, "time", return_value=1000):
                with self.assertRaisesRegex(ValueError, "timestamp"):
                    watch.snapshot(rpc, "0x" + "1" * 40, 31337, "finalized", 100)


if __name__ == "__main__":
    unittest.main()
