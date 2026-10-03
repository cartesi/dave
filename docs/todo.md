# To-do

The one live list of agreed work. An item is one or two lines: the work, a
clause of why, and the living doc that owns its reasoning. A done item is
deleted; the commit that lands it updates the owner doc. Dated review records
carry no backlog (reviews/README.md).

## Next release

- Cut a release candidate after this PR for the staging pipeline and
  testnet. It is a new deployment generation: 2c502f63 changed the
  `TournamentParameters` row and the clone arguments, so this node cannot
  start against earlier contracts. The release notes name the generation,
  its addresses, geometry and bonds. (build-system.md, CHANGELOG.md)
- Operator notes in the node README: a warning that repeats every tick is a
  stall (restart after a fold error, rebuild after an input gap); on
  foreclosure, stop the node once its recoveries finish; an epoch lasts at
  least the root allowance, plus the staging period unless every sentry
  agrees. (node-architecture.md, epoch-lifecycle.md)

## Before the canonical two-level switch (a later PR)

- Switch `ArbitrationConstants` to two levels, `[37, 0]` / `[55, 37]` with
  `COMMITMENT_BUDGET = 60 minutes`, plus `testCheckedInCanonicalTable`,
  through the contract-change gate; regenerate bindings and the devnet, and
  recompute the node README's funding floor for the new bonds.
  (dimensioning.md)
- Place `stf_all` and `stf_revert` once leaves are two-level: the node
  harness, or e2e on a small test-shape table kept under `test/` behind the
  devnet guard. (test-harness.md)
- After the switch, retire `DEVNET_GEOMETRY`: the devnet-only two-level
  deployment, its CI smoke, the fingerprint branch, and the duplicated literal
  in `TournamentGeometry::two_level`. (build-system.md)
- On the first two-level staging, stop and restart the node mid leaf build:
  three-level releases never take the span-by-span, resumable tall build,
  which only the spec, engine-machine and two-level devnet tests exercise.
  (computation-hash.md)

## Before a two-level release

- Confirm `[55, 37]` at `T = 60` on v0.21 and validator-grade hardware, and
  settle which root-slowdown figure governs stride 37 (the hash-cost hump at
  2^16 to 2^18 big cycles); the per-input compute contract's numbers and the
  worst-case leaf proof plus fallback latency (CF-01) follow from it.
  (measurements/constants.md, dimensioning.md)
- Link a tagged emulator release; development may pin unreleased commits.
  (build-system.md)

## Upstream (Cartesi Machine, arm's length: nothing waits on it)

- Ask for a v0.21.1 with c1280ed4's collector, break-precedence and host-send
  no-op hunks (not its cmio length-width break) and 22b4431's CLI boundary
  capture; close-on-exec on the files os-filesystem.cpp creates and flocks; a
  hash-tree parallelism threshold based on work, not core count; corpus vectors
  at both seams with later inputs; a collector assert for a non-pristine uarch.
  On release, drop the seam-1 guard and its control test, the CLI exclusions,
  and the serial anvil-test workaround. (computation-hash.md)
- Ask for a solidity-step release that exports `CM_MARCHID`.
  (computation-hash.md)
- Track upstream PR #390 (new pristine uarch hash and proof format) as its own
  coordinated generation. (build-system.md)

## Node

- Audit panics, asserts and retry loops against P1 (debt 3). Targets: the
  Hero's remaining `expect`s; dispute-path validators stricter than the
  contracts; `read_standings`, where one bad standing fails the whole Hero
  tick; Solid, which keeps a missed finalized log until a restart; bond
  recovery, which runs serially before every wave; the reader's `expect`s on
  finalized log data; the terminal-application hold, which has no
  `settles()` test for a `TX_EXCEPTION` yield. A retry loop that should page
  reuses the epoch manager's consecutive-tick rule (`repeated_reverts`: a
  warning first, an error on the next tick). (node-architecture.md, failure
  policy)
- Pin the settle asserts' staging and accept reads to the Hero's observed
  head (or to finalized): read at a fresh latest, a tip reorg may fire them
  once without a node bug (a lead). (epoch-lifecycle.md, settlement
  invariant)
- After that audit, prune dispute-path validators that re-check what the
  contracts enforce (P1, bounded by P2: keep the checks whose absence makes a
  lie silent). Before pruning one that guards an engine assert, make the
  assert an error, or the prune turns a retry into a common-mode panic. The
  unmarked cases: `MatchHeightOutOfRange`, which guards `LevelCoords::node`,
  and the `children` expect in `engine/dispute.rs`. (node-architecture.md,
  failure policy)
- Structured logging (debt 4). (node-architecture.md)
- Delete the commented-out reference code (debt 8). (node-architecture.md)
- Check that the Latest tail descends from Solid's finalized block, by parent
  hashes, instead of trusting a number range (debt 10; today the estimate
  pre-check of 8ace5822 is the backstop). (node-architecture.md)

## Contracts and assurance

- An independent honest-survival model (R19) before the external audit:
  [plans/r19-honest-survival.md](plans/r19-honest-survival.md).
  (dispute-game.md)
- Prepare the external contracts audit: scope, trust boundaries, non-claims,
  the pre-audit items below, freeze and audit identity:
  [plans/audit-readiness.md](plans/audit-readiness.md).
  (prt/contracts/AGENTS.md)
- Run the full-stack leaf-proof gas witnesses
  (`rollups-contracts::test-prt-leaf-gas`) in CI: `rollups-contracts::test`
  skips the FFI suites and no workflow calls the recipe; the Tournament-only
  witnesses already run inside `test-disputes`.
  (runbooks/prt-refund-gas-calibration.md)
- Replace the local `CM_MARCHID = 21` in `CartesiStateTransition` with
  solidity-step's constant once a release exports it; it moves deployed
  addresses, so it rides the next deployment bundle (normally the next
  generation). (computation-hash.md)
- Review contract code shaped for tests (`Deployment.s.sol`'s
  `commitmentBudget` parameter, which only the devnet script uses), say that
  on-chain geometry validation is test-only, and make the canonical validator
  test check the real rows: it runs its refill check with `T = 0`.
  (prt-contract-testing.md)
- Write a deployment runbook: chains, parameters, broadcast, address
  verification against the release asset, post-deploy checks.
  (build-system.md, deployment generations)

## Tests

- Pin the capacity boundaries: the last input slot and the last stride.
  (test-harness.md)
- When the development emulator pin leaves v0.21.0, check the linked
  library's pristine uarch hash and marchid against solidity-step, and identify
  the reference CLI by package digest instead of its version string.
  (test-harness.md)
- Optional: a steered divergence point for the harness's tail adversary, to
  dispute active spans in-process. (test-harness.md)

## Tooling

- The toolchain is off the bare PATH (forge, the CLI and the pinned emulator
  come from the nix devshell): recipes that enter it, or a doctor check that
  names the fix. (build-system.md)
- Soldeer keeps old dependency versions after a bump, which poisons the
  leaf-gate dependency digest (ca1b0357); prune them or digest only the pinned
  versions. (runbooks/prt-refund-gas-calibration.md)
- Fix the measurement generator's wording for `G` and regenerate the
  measurements, whose checked-in prose still names `matchEffort`.
  (dimensioning.md)

## Decisions

- The tournament events ABI stays as is in this PR; a follow-up may add
  fields if consumers request them.
- The safety-gate branch stays tabled: the delay lives in DaveConsensus
  staging and sentries, and the branch is kept for its `ITask` genericity.
- Open: the external audit's scope, firm and date, and whether R19 gates it
  (plans/audit-readiness.md).
