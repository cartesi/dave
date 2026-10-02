---
name: add-e2e-scenario
description: Add or wire a new e2e test scenario for the PRT rollups harness (test/e2e/rollups). Use when creating a scenario, adding a sybil scenario, or wiring an existing scenario into the smoke that CI runs.
---

# Add an e2e scenario

Full harness context: `docs/test-harness.md` (anatomy, oracle doctrine,
patch chains, kill markers). The wiring checklist, complete:

1. Pick or build a machine program under `test/programs/` (see its
   justfile). Existing: echo, yield, honeypot; `compute` builds but is
   not yet wired into any scenario.
2. Write `test/e2e/rollups/scenarios/<name>.lua`: require `test_env`,
   spawn blockchain and node, drive epochs with `run_steered_epoch` when
   the dispute must reach a specific transition, and with `run_epoch` or
   hand-rolled sybils with patch lists otherwise. Take strides and heights
   from `env.reader:read_tournament_levels()`, never literals, so the
   scenario runs on either devnet geometry. Copy the shape of a sibling
   scenario (`simple.lua` for honest runs, `stf_all.lua` for steered
   disputes, `kill_*.lua` for kill points, `multi_sybil.lua` for concurrent
   matches).
3. Wire a justfile alias if it should run in a suite
   (`test/e2e/rollups/justfile`). Give the recipe a self-contained
   final comment line - `just --list` shows only that line.
4. Add `<program> <name>` to the `smoke` recipe's list in the same
   justfile. Per-PR CI runs `just e2e-smoke`, so the list is the PR gate;
   a scenario missing from it never runs and draws only a warning.

Run it: `just rollups-tests::test <program> <name>`, or with
`TEST_INSTANCE=<free port>` for an isolated parallel lane. Read
results honestly with `just logged`. Use the same `TEST_INSTANCE=<id>`
when running `just view-rollups-logs`; without it, that recipe follows
the default `dave.log`. Sweep with `just rollups-tests::sweep` after
reading results.
