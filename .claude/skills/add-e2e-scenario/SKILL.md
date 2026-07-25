---
name: add-e2e-scenario
description: Add or wire a new e2e test scenario for the PRT rollups harness (prt/tests/rollups). Use when creating a test case, adding a sybil scenario, or wiring an existing case into suites, CI, or the battery.
---

# Add an e2e scenario

Full harness context: `docs/test-harness.md` (anatomy, oracle doctrine,
patch chains, kill markers). The wiring checklist, complete:

1. Pick or build a machine program under `test/programs/` (see its
   justfile). Existing: echo, yield, honeypot; `compute` builds but is
   not yet wired into any scenario.
2. Write `prt/tests/rollups/test_cases/<name>.lua`: require `test_env`,
   spawn blockchain and node, drive epochs with `run_epoch` or
   hand-rolled sybils with patch lists. Copy the shape of a sibling
   case (`simple.lua` for honest runs, `kill_*.lua` for kill points,
   `multi_sybil.lua` for concurrent matches).
3. Wire a justfile alias if it should run in a suite
   (`prt/tests/rollups/justfile`). Give the recipe a self-contained
   final comment line - `just --list` shows only that line.
4. Add it to `battery.sh`'s `SCENARIOS` array if it should run in the
   full parallel battery. The array is independent of the justfile
   aliases and does not inherit from them; a scenario missing here is
   omitted from execution and produces only a non-fatal warning. If the
   scenario is deliberately excluded, add its bare script name to
   `EXCLUDED_SCENARIOS` and put the reason in an adjacent comment.
5. If it should gate PRs, add the just target to
   `.github/workflows/build.yml` - CI calls just targets by name, never
   inline commands.

Run it: `just rollups-tests::test <program> <name>`, or with
`TEST_INSTANCE=<free port>` for an isolated parallel lane. Read
results honestly with `just logged`. Use the same `TEST_INSTANCE=<id>`
when running `just view-rollups-logs`; without it, that recipe follows
the default `dave.log`. Sweep with `just rollups-tests::sweep` after
reading results.
