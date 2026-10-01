# Test strategy reset

Opened 2026-10-01. The e2e suite had been driving changes: most of the
two-level session's churn went into adapting scenarios to a second geometry,
while the real bugs were found by Foundry and by benchmarks. This plan
restates what each layer must establish, records what is verified today, and
orders the work. It supersedes the e2e-cost items of two-level-sling.md
(W4.8, R6) where they conflict.

## What each layer must establish

- Solidity: Foundry only. The dispute tests and the step tests (FFI against a
  real machine) are the confidence source; no node is involved.
- The node: correct computation hashes and proofs, built in time, with
  bounded memory and reasonable disk, in two regimes. Eager: the runner in an
  open epoch executes, samples at the root stride, folds window roots and
  keeps snapshots. Lazy: a dispute positions from snapshots and builds
  quartets, leaves and proofs.
- End to end: only what needs a chain and the node's process: the sender,
  the epoch lifecycle (settle, stage, GC, bond recovery), the Hero against
  adversaries, and crash recovery.

## Verified today (investigation of 2026-10-01)

Correctness is well covered on the lazy path, but not completely:

- The toy spec checks every stride and position on tiny shapes. The
  real-machine differentials (`engine_machine.rs`) check a few shapes on the
  echo and yield images against a test-only prototype that shares the
  Merkle builder. The release corpus checks 17 mcycle cases; its 18 uarch
  cases are skipped. Storage tests use synthetic runs.
- Gaps covered only by e2e, by priority: (1) the Solidity step accepting the
  node's proof bytes (Foundry checks Lua witnesses only); (2) the eager
  runner on a real machine (advance, record, commit, roll); (3) independent
  answers at stride 0 and at the deployed root strides; (4) dense leaves and
  reverts through the big-cycle-root builder on a real machine; (5)
  commitment proofs and the settlement validity proof against the contracts.
- Lua-versus-node agreement is not a production requirement: once the node
  is tied to CLI answers and to Solidity, Lua only needs to agree for e2e
  steering.

Timing, memory and disk have no tests. `measure.rs` reports but asserts
nothing; M2 measured one leaf build (1,100 s, 103 MiB).

The e2e harness mines one block per poll, so it cannot represent wall-clock
budgets. On the two-level devnet the debug node needs 13 to 38 min for
yield's dense leaves against a clock of about 375 blocks, and yield
`stf_revert` passed there earlier only because the slow leaf-by-leaf Lua
sybil froze block production while it computed. The canonical battery passes.

## Plan

1. Correctness gaps without e2e, in order: the eager runner on a real
   machine, asserting settlement root = lazy dispute root on a fresh store =
   a checked-in CLI golden (gap 2); node witnesses through Foundry FFI (gap
   1); the uarch and Dave-owned corpora (gap 3); a dense-leaf and revert
   differential through the big-cycle-root builder (gap 4); checked-in proof
   vectors in Foundry (gap 5); a unit test for resuming a half-built level.
   Gap 2 is done: `runner_settles_the_reference_root` drives the
   production runner over an echo epoch (a rejection mid-batch, a sealed
   remainder) and an all-rejected yield epoch under both tables; the
   settled root equals the facade's root from the runner's rows, the
   replay on a fresh store, and `tests/fixtures/reference_cli.json`, which
   `just test-reference-cli-goldens` recomputes with the released CLI in
   CI's e2e lane. Gap 1 is done with checked-in vectors rather than FFI
   (Foundry would otherwise build and run the node): `node_witness_vectors_hold`
   pins the node's witness bytes for six transition shapes, and
   `NodeWitnessesTest` in `cartesi-rollups/contracts` replays them through
   the step. Gaps 3 and 4 are done for Dave-owned cases:
   `leaf_commitments_match_the_reference_cli` checks nine stride-0 leaves on
   echo and yield (a fed window start, an accepted yield, two reverts, a
   revert crossed while positioning, a padding window) against the CLI's
   uarch cycle computation hash at period 8 (the big-cycle-root builder) and
   period 7 (plain collection). The CLI computes them through the collect
   API, which ties the node's per-step hashing to that API before the switch
   (W6). Period 17 is impractical as a golden: the CLI spends about 2 minutes
   on a mostly idle leaf there and more than 13 on a dense one. The release
   corpus's uarch cases are wired too: 16 of 18 match, one has no released
   hash, and `uarch-near-limit-tail` is out of model (a template with
   custom uarch code; Solidity, the CLI and Dave give three roots). Gap 5 is done:
   `node_proof_vectors_hold` pins commitment proofs and a settlement validity
   proof, and `NodeProofsTest` checks them with the contracts' own verifiers
   against the CLI's outputs Merkle root; the runner test also requires the
   CLI's final state. The resume test is done:
   `restarted_source_resumes_a_half_built_level` restarts a dispute source
   over a killed one's stored strata and write-backs and requires a fresh
   store's root and proofs (the unit form of `kill_commitment_build`).
2. Timing, as designed with the owner on 2026-10-01. The node's claim is
   that it adds no overhead over the emulator; whether a geometry fits an
   app on given hardware belongs to the machine team, which measures the
   geometry and timeouts with the emulator, and to the operator. Average
   apps, operators and machines: a byzantine or fp-heavy app that forces
   the worst case is out of scope (a future emulator-assisted eager check
   could drop such an app before a dispute). So:
   - CI gates work counts only: deterministic, hardware-free, and stated
     against the emulator's irreducible work (a leaf build runs each ustep
     once, an idle stretch costs one cycle, positioning replays an input at
     most once per action, folded spans cost no machine work). A
     regression is an algorithm bug and fails the PR. Nothing in CI times
     anything, and no counts x atoms arithmetic gate is built.
   - The runbook (before releases or hot-path changes) reports the node's
     time over the emulator's on the same span and host, plus RSS and disk.
     The ratio is what lets the machine team's numbers apply to the node
     (the OpenMP cliff would have read about 7x). A `measure.rs` recipe,
     when it is next touched.
   - At runtime the node logs each expensive dispute action's duration
     next to the clock time left and warns when one used more than half;
     it never refuses to run for performance.
   - Disk: a CoW filesystem (APFS, btrfs, XFS with reflink) is a documented
     requirement, not a check. `clone_stored` falls back to sparse copies,
     so correctness is the same everywhere, and CI stays on ext4.

   Done: the work-count tests in `engine/spec.rs` (a metered toy at the
   production structure: the eager window, the dense leaf, positioning, and
   the join descent, which pins R4's four extra prefix replays) and
   `positioning_resumes_from_the_nearest_gap_snapshot` on echo; the Hero
   logs each prepared action's duration; the README states the CoW
   requirement. Not built: the clock-time-left comparison. The Hero's domain
   omits clocks by design, so it would need a `commitmentStanding` read per
   action (and the join window for joins); open for the owner.
3. An anvil harness inside the crate: drive the epoch manager and the Hero
   against deployed contracts with mined blocks, with the node's own engine
   plus a test patch layer as the adversary. It covers the sender, the
   lifecycle and the timeouts deterministically (the sealed-leaf timeouts
   move here).
4. A small black-box e2e on a test-shape profile (for example
   `[63/29, 42/21, 21/21, 0/21]`, which caps leaves at 2^21 usteps and keeps
   middle levels exercised) plus a canonical smoke: honeypot simple, echo
   `stf_all`, yield `stf_revert`, chaos at a fixed seed, `multi_sybil` and one
   kill. Heights always sum to 92, so disputes keep about 92 rounds; the
   profile only makes leaves cheap. The yield copies of honeypot scenarios,
   `kill_catchup_batched`, `deposit_withdrawal`, `simple_no_input` and
   `bad_commitment` are redundant. The Lua oracle lineage and the CLI gate go
   once gap 2 lands.

## Reconsider (from this branch)

- `DEVNET_GEOMETRY` (fe3d113f): one bundle and port for two geometries
  caused most devnet rebuilds. Retire it at W5 or turn it into the
  test-shape profile.
- The sealed-leaf timeout helper (812f677e): Foundry covers the contract
  semantics; its node part belongs in the anvil harness.
- The CLI gate in the e2e oracle (5ecd86b3): a third computation of every
  epoch with an exact version pin, checking roots only; move it to corpus
  level.
- The collector-based Lua leaf builder, parked on
  `wip/lua-collector-leaf-builder` (3f722e6e): not to land as written (it
  hooks a machine replay into `Hash:children()` and makes the collector the
  reference client's default). Keep it sybil-only under `test/e2e/support`,
  or drop it in favor of light-span scenarios.
- The devnet censorship budget of 0 (a lead): kill and chaos scenarios keep
  no slack, so a slow debug build reads as a correctness failure.

## Deferred: Solidity

- Test coverage, and where contracts were shaped for tests: for example the
  `get...Count` counters, which no client reads but every structural action
  pays for, and `Deployment.s.sol`'s helpers refactored for a script under
  `test/`.
- Configuration: tournament geometry and budgets; the table validator is
  test-only while production validates nothing on chain.
- Deployment.
- A full audit.
