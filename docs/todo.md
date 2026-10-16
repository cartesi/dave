# To-do

The one live list of agreed work. An item is one or two lines: the work, a
clause of why, and the living doc that owns its reasoning. A done item is
deleted; the commit that lands it updates the owner doc. Dated review records
carry no backlog (reviews/README.md).

## Next release

- Cut a release candidate after the canonical two-level switch for the
  staging pipeline and testnet; it does not wait for the validator-grade
  confirmation below. It is a new deployment generation, whose notes are
  CHANGELOG.md's Unreleased section: at the cut, title it with the tag and
  add the generation's addresses. (build-system.md, CHANGELOG.md)

## Before the audited release

- Confirm `[38, 0]` / `[54, 38]` at `T = 120` on validator-grade hardware
  (measured on one M5 Max laptop, v0.21.0; re-measure on v0.22, whose uarch
  changed); the per-input compute contract
  and the worst-case leaf proof plus fallback latency (CF-01, one shared
  `G` for both landings) follow from it, and re-measure the heaviest
  instruction's usteps while there.
  (measurements/constants.md, dimensioning.md)
- Price input volume against the root window in the DaveConsensus campaign:
  sealing takes every input before the acceptance block with no cap or
  minimum notice, and the app's aggregate-throughput contract is what makes
  the honest root join land. (dimensioning.md)
- On the release candidate's staging, the first on two levels, stop and
  restart the node mid leaf build: three-level releases never took the
  span-by-span, resumable tall build, which only the spec and engine-machine
  tests exercise. Take a dispute there through the height-38 leaf seal (an
  even height, so commitment two seals), the step proof and settlement, since
  nothing has run the canonical table node-against-chain.
  (computation-hash.md, dispute-game.md)

## Upstream (Cartesi Machine, arm's length: nothing waits on it)

- Ask for a hash-tree parallelism threshold based on work, not core count;
  corpus vectors at both input-budget seams with later inputs; a collector
  assert for a non-pristine uarch; and a CLI that delivers to a halted
  template with an input yield pending, as the step does (a lead).
  (computation-hash.md)
- Track upstream PR #390 (new pristine uarch hash and proof format) as its own
  coordinated generation. (build-system.md)

## Node

- Measure and write down the node's supported workload envelope (inputs,
  live tournaments, provider capacity, action latency), in the steady state
  and under the dimensioned attack, the post-closure staggered-release
  regime included:
  [plans/provider-requirements.md](plans/provider-requirements.md).
  (dimensioning.md, prt-delay-bound.md)
- Take the contracts' composition contract for the honest node
  (reviews/2026-10-13-prt-cyber-verification/HONEST-NODE-CONTRACT.md) as
  the node campaign's brief: the revert-protecting endpoint as required once
  a relay passes runbooks/submit-relay.md, superseding a pending transaction
  only if no relay operators use frees a held nonce within G, planning the
  timeout claim when the opponent's leaf clock cannot outlive the proof, and
  the two planner leads recorded there. (node-architecture.md)
- Qualify Flashbots Protect (default and `/fast`) and MEV Blocker
  `/noreverts` on mainnet with a small dedicated funded key, record the results and
  update the node README's candidate list: no relay is measured yet.
  (runbooks/submit-relay.md)

## Contracts and assurance

- Review the honest-survival argument (dimensioning.md, "Honest survival
  under the budgets") by someone other than its author, and decide whether
  the two-level search gates the external audit or is handed over as
  evidence. (dispute-game.md)
- Re-evaluate the pinned solc against its bug list at the audit freeze: one
  Yul optimizer entry fixed after 0.8.37 cannot be excluded by reading.
  (plans/audit-readiness.md)
- Prepare the external contracts audit: scope, trust boundaries, non-claims,
  the pre-audit items below, freeze and audit identity:
  [plans/audit-readiness.md](plans/audit-readiness.md).
  (prt/contracts/AGENTS.md)
- Review contract code shaped for tests (`Deployment.s.sol`'s
  `commitmentBudget` parameter, which only the devnet script uses), and say
  that on-chain geometry validation is test-only. (prt-contract-testing.md)
- Write a deployment runbook: chains, parameters, broadcast, address
  verification against the release asset, post-deploy checks.
  (build-system.md, deployment generations)
- If a table with three or more levels leaves test-only use, retain an
  inner-elimination witness in a middle tournament: the non-root standing
  branch there is estimated at about 153,000 units, reviewing above
  `ELIMINATE_INNER_TOURNAMENT`.
  (reviews/2026-10-11-prt-events-gas-calibration)

## Tests

- Pin the capacity boundaries: the last input slot and the last stride.
  (test-harness.md)
- Identify the reference CLI by package digest instead of its version
  string, which cannot tell the release from its pre-releases or from an
  unreleased upstream build.
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
- `just measure-prt-gas` fails its dependency digest with no hint when stale
  dependency directories sit beside the pinned ones (copied rollups-contracts
  alpha.6 and alpha.9): name the extra and missing directories, and let doctor
  check them. (runbooks/prt-refund-gas-calibration.md)
- On macOS the e2e recipes run throttled unless the machine is held awake
  (smoke `simple`: 121 s under caffeinate, 1,669 s without, so `stf_all` hit
  its deadline): hold it awake from the recipe on Darwin. (test-harness.md)

## Decisions

- The tournament events carry the match schedules, sealed divergences,
  descriptors, bonds and `StandingChanged` that consumers asked for, in
  cartesi/dave#287's generation (cartesi/dave#297). A later field is a wire
  break: it lands before the audit freeze or waits for the next generation.
  (dispute-game.md)
- The safety-gate branch stays tabled: the delay lives in DaveConsensus
  staging and sentries, and the branch is kept for its `ITask` genericity.
- Open: the external audit's scope, firm and date, and whether R19 gates it
  (plans/audit-readiness.md).
