#!/usr/bin/env python3
"""Recovery refusal rules and operator confirmation boundaries."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recovery = load("settlement-recover")
operator = load("settlement-operator")
H = "0x" + "11" * 32
A = "0x" + "22" * 20


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.expected = dict(chain_id=31337, consensus=A, app=A, epoch=1, commitment=H, final_state=H, outputs_root=H)
        self.snapshot = dict(app=A, epoch=1, winner=H, winner_state=H, staged_state=H,
                             staged_outputs=H, phase="acceptance_ready", block=10, block_hash=H)

    def prepare(self, expected=None, phase=None):
        snapshot = dict(self.snapshot, phase=phase or self.snapshot["phase"])
        with patch.object(recovery.watch, "snapshot", return_value=snapshot):
            with patch.object(recovery.subprocess, "check_output", return_value="0x1234"):
                def rpc(method, _):
                    return "0x" if method == "eth_call" else {"hash": H}
                return recovery.prepare(rpc, expected or self.expected, "accept", A, 1800)

    def test_verified_acceptance_is_simulated(self):
        self.assertEqual(self.prepare()["transaction"], dict(to=A, **{"from": A}, data="0x1234", value="0x0"))

    def test_disagreement_and_wrong_epoch_are_refused(self):
        for key, value in [("epoch", 2), ("commitment", "0x" + "33" * 32),
                           ("final_state", "0x" + "44" * 32), ("outputs_root", "0x" + "55" * 32)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.prepare(dict(self.expected, **{key: value}))

    def test_acceptance_during_wait_failed_root_or_foreclosure_is_refused(self):
        for phase in ["staging_wait", "root_failed", "foreclosed", "tournament_in_progress"]:
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                self.prepare(phase=phase)

    def test_proof_cannot_silently_change_outputs(self):
        leaf = dict(data_block=H, siblings=[])
        proof = dict(iflags_y=leaf, htif_tohost=leaf, tx_buffer=leaf)
        with self.assertRaises(ValueError):
            recovery.proof_argument(proof, "0x" + "33" * 32)

    def test_simulation_failure_is_not_a_plan(self):
        with patch.object(recovery.watch, "snapshot", return_value=self.snapshot):
            with patch.object(recovery.subprocess, "check_output", return_value="0x1234"):
                with self.assertRaisesRegex(RuntimeError, "revert"):
                    recovery.prepare(lambda *_: (_ for _ in ()).throw(RuntimeError("revert")), self.expected, "accept", A, 1800)

    def test_wrapper_does_not_prepare_without_confirmation(self):
        args = SimpleNamespace()
        with patch.object(operator, "confirmed", return_value=False), patch.object(operator.recover, "prepare") as prepare:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(operator.operate(dict(verdict="stalled", phase="acceptance_ready", epoch=1), args), 2)
            prepare.assert_not_called()

    def test_wrapper_does_not_submit_without_second_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence.json"
            evidence.write_text(json.dumps(self.expected))
            args = SimpleNamespace(evidence=evidence, sender=A, consensus=A, chain_id=31337,
                                   rpc_url="http://unused", account="operator", unlocked=False, max_head_age_seconds=1800)
            with patch.object(operator, "confirmed", side_effect=[True, False]):
                with patch.object(operator.recover, "prepare", return_value={"verdict": "simulated"}):
                    with patch.object(operator.subprocess, "run") as send, contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(operator.operate(dict(verdict="stalled", phase="acceptance_ready", epoch=1), args), 2)
                        send.assert_not_called()

    def test_changed_result_after_review_prevents_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence.json"
            evidence.write_text(json.dumps(self.expected))
            args = SimpleNamespace(evidence=evidence, sender=A, consensus=A, chain_id=31337,
                                   rpc_url="http://unused", account="operator", unlocked=False, max_head_age_seconds=1800)
            with patch.object(operator, "confirmed", return_value=True):
                with patch.object(operator.recover, "prepare", side_effect=[{"transaction": {}}, ValueError("epoch changed")]):
                    with patch.object(operator.subprocess, "run") as send, contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaisesRegex(ValueError, "epoch changed"):
                            operator.operate(dict(verdict="stalled", phase="acceptance_ready", epoch=1), args)
                        send.assert_not_called()


if __name__ == "__main__":
    unittest.main()
