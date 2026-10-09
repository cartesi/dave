---
name: add-e2e-scenario
description: Add or wire an e2e scenario for the PRT rollups harness (test/e2e/rollups), the slim black-box smoke that runs the node as a process against Lua sybils. Use when creating or wiring a scenario; first check whether the test belongs in the node's anvil harness or in Foundry instead.
---

# Add an e2e scenario

E2E is the outer net: the node binary as a process, real signals, Lua sybils
over a real dispute. Route the test to the cheapest layer that can establish
it first (`docs/test-harness.md`, "What each layer establishes"):

- Lifecycle, settlement and staging, cleanup, bond recovery, restarts at a
  chosen action, several sybils, timeouts and deadline edges: the node's
  in-crate harness (`cartesi-rollups/node/src/harness/`,
  `just test-node-harness`), where the test owns the clock and the adversary
  is the production Hero over a test-only tail.
- Commitment values, leaves, witnesses and proofs:
  `cartesi-rollups/node/tests/engine_machine.rs` goldens and vectors, replayed
  through the step in Foundry (`NodeWitnessesTest`, `NodeProofsTest`).
- Contract semantics: Foundry (`docs/prt-contract-testing.md`).

Only what needs the process stays here. Full harness context:
`docs/test-harness.md` (anatomy, oracle doctrine, patch chains, kill markers).
Then:

1. Pick a machine program under `test/programs/`: echo, yield, or the opt-in
   honeypot, which CI does not build; `stress` serves the Rust measurements
   only.
2. Write `test/e2e/rollups/scenarios/<name>.lua`: require `test_env`, spawn
   blockchain and node, drive epochs with `run_steered_epoch` when the dispute
   must reach a specific transition and with `run_epoch` otherwise. Take
   strides and heights from `env.reader:read_tournament_levels()`, never
   literals, so the scenario runs on any table. Copy a sibling:
   `simple.lua` (one dispute), `stf_all.lua` (steered disputes),
   `kill_catchup_batched.lua` (a kill on a log marker; a new marker joins the
   contract in `docs/test-harness.md`, "Node introspection seam").
3. Add `<program> <name>` to the `smoke` recipe's list in
   `test/e2e/rollups/justfile`. Per-PR CI runs `just e2e-smoke`, so the list
   is the PR gate; a scenario missing from it never runs and draws only a
   warning.

Run it: `just e2e <program> <name>`, or with `TEST_INSTANCE=<free port>` for
an isolated parallel lane. Read results honestly with `just logged`. Use the
same `TEST_INSTANCE=<id>` with `just e2e-logs`; without it, that recipe
follows the default `dave.log`. Sweep with `just rollups-tests::sweep` after
reading results.
