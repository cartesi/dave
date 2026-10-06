# To-do

The one live list of agreed work. An item is one or two lines: the work, a
clause of why, and the living doc that owns its reasoning. A done item is
deleted; the commit that lands it updates the owner doc. Dated review records
carry no backlog (reviews/README.md).

## Next release

- Cut a release candidate after this PR for the staging pipeline and
  testnet. It is a new deployment generation, whose notes are CHANGELOG.md's
  Unreleased section: at the cut, title it with the tag and add the
  generation's addresses. (build-system.md, CHANGELOG.md)

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

- Prune dispute-path validators that re-check what the contracts enforce
  (P1, bounded by P2: keep the checks whose absence makes a lie silent). The
  coordinate validators front engine asserts: keep each, or make the asserts
  it fronts errors in the prune's first commit, or the prune turns a retry
  into a common-mode panic. `InvalidBisectingHeight` must keep its bound of
  2, not relax to nonzero. (node-architecture.md, failure policy)
- Give the submit client its own configuration: sends are idempotent raw
  transactions with nonces from the mined count, so their retry and timeout
  needs differ from reads', and a relay's errors differ from a node's. Today
  both endpoints share `create_client`. (node-architecture.md, RPC client)
- Measure and write down the node's supported workload envelope (inputs,
  live tournaments, provider capacity, action latency), in the steady state
  and under the dimensioned attack:
  [plans/provider-requirements.md](plans/provider-requirements.md).
  (dimensioning.md)

## Contracts and assurance

- An independent honest-survival model (R19) before the external audit:
  [plans/r19-honest-survival.md](plans/r19-honest-survival.md).
  (dispute-game.md)
- Prepare the external contracts audit: scope, trust boundaries, non-claims,
  the pre-audit items below, freeze and audit identity:
  [plans/audit-readiness.md](plans/audit-readiness.md).
  (prt/contracts/AGENTS.md)
- Replace the local `CM_MARCHID = 21` in `CartesiStateTransition` with
  solidity-step's constant once a release exports it; it moves deployed
  addresses, so it rides the next deployment bundle (normally the next
  generation). (computation-hash.md)
- Review contract code shaped for tests (`Deployment.s.sol`'s
  `commitmentBudget` parameter, which only the devnet script uses), and say
  that on-chain geometry validation is test-only. (prt-contract-testing.md)
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
- Release-candidate hardening: a harness test in which a terminal
  application's epoch is defended, won and held through the real contracts.
  It needs a guest that turns terminal on an input, a new test image, since
  startup refuses a template that is terminal at genesis; today the epoch
  manager's tests pin the hold against mocked views. (test-harness.md)

## Tooling

- The toolchain is off the bare PATH (forge, the CLI and the pinned emulator
  come from the nix devshell): recipes that enter it, or a doctor check that
  names the fix. (build-system.md)
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
