---
name: add-e2e-scenario
description: Add or wire a new e2e test scenario for the PRT rollups harness (test/e2e/rollups). Use when creating a scenario, adding a sybil scenario, or wiring an existing scenario into the smoke that CI runs.
---

# Add an e2e scenario

Full harness context: `docs/test-harness.md` (anatomy, oracle doctrine,
patch chains, kill markers). The wiring checklist, complete:

1. Pick or build a machine program under `test/programs/` (see its
   justfile). Existing: echo, yield, and the opt-in honeypot, which CI
   does not build; `stress` serves the Rust measurements only.
2. Write `test/e2e/rollups/scenarios/<name>.lua`: require `test_env`,
   spawn blockchain and node, drive epochs with `run_steered_epoch` when
   the dispute must reach a specific transition, and with `run_epoch` or
   hand-rolled sybils with patch lists otherwise. Take strides and heights
   from `env.reader:read_tournament_levels()`, never literals, so the
   scenario runs on either devnet geometry. Copy the shape of a sibling
   scenario (`simple.lua` for honest runs, `stf_all.lua` for steered
   disputes, `kill_catchup_batched.lua` for kill points).
3. Add `<program> <name>` to the `smoke` recipe's list in
   `test/e2e/rollups/justfile`. Per-PR CI runs `just e2e-smoke`, so the
   list is the PR gate; a scenario missing from it never runs and draws
   only a warning.

Run it: `just e2e <program> <name>`, or with `TEST_INSTANCE=<free port>`
for an isolated parallel lane. Read results honestly with `just logged`.
Use the same `TEST_INSTANCE=<id>` when running `just e2e-logs`; without
it, that recipe follows the default `dave.log`. Sweep with
`just rollups-tests::sweep` after reading results.
