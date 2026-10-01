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
2. Timing as cost = counts x atoms. Design this properly before building it
   (owner, 2026-10-01: benchmarks are hard); what follows is the starting
   sketch, not the design. Exact work counts at the production
   geometry are deterministic unit tests on the toy (a counting stf: runner
   collects, leaf builds, descents, `prove_last`, snapshot rows, gap replay).
   Release-build atoms are measured (dense pair rate, stride-37 sampling,
   plain runs, store time and physical bytes, deep proofs). A per-PR
   arithmetic gate checks atoms x counts x slack against `G`, `T + 2G` and the
   roll, so a change to the gap, the precompute strata, the geometry or the
   per-input contract fails loudly. A pre-release runbook on the reference
   machine (M2, constants, a write-TLB-heavy leaf, gap-1 replay, disk, RSS)
   checks the extrapolation. Prerequisite: a stress guest whose payload sets
   cycles, density and pages touched.
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
