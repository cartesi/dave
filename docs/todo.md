# To-do

The one live list of agreed work. An item is one or two lines: the work, a
clause of why, and the living doc that owns its reasoning. A done item is
deleted; the commit that lands it updates the owner doc. Dated review records
carry no backlog (reviews/README.md).

## Before the audited release

- Confirm `[38, 0]` / `[54, 38]` at `T = 120` on validator-grade hardware
  (measured on one M5 Max laptop, v0.21.0; re-measure on v0.23, whose uarch
  changed); the per-input compute contract
  and the worst-case leaf proof plus fallback latency (CF-01, one shared
  `G` for both landings) follow from it, and re-measure the heaviest
  instruction's usteps while there. Time one root response and one leaf
  build while a runner batch of stress inputs runs (the two share cores with
  no priority), and count one re-preparation of a leaf proof still pending
  at the next tick in the fallback latency. Measure on Linux XFS on a cloud
  volume, since every figure so far is APFS and a Linux clone writes back
  the source's dirty pages first: the runner's whole time per input (15 to
  18 ms accepted and 22.6 ms rejected on macOS with v0.23, echo, against the
  36 ms threshold; time it on local NVMe and on the cloud volume at baseline
  provisioning), the clone's latency and bytes written per input with a
  dirty source, the runner's sustained inputs per second for accepted,
  rejected and alternating inputs (a fixture that rejects by payload), and
  the disk per snapshot at the default gap. The default gap and the
  aggregate-throughput price follow from them. A lead to verify there, the
  emulator team's figures on their host and echo image, not ours: on XFS
  with v0.23 a load takes 2.2 ms, the first root hash 3.0 ms, the root hash
  after the input 10.0 ms, and the input itself about 40 ms on a fresh
  reflinked clone against about 10 ms once the clone is in memory (a
  reflink shares disk blocks with its source, not cached pages). If ours
  agree, a Linux input is over the 36 ms threshold.
  (measurements/constants.md, dimensioning.md)
- On the release candidate's staging, the first on two levels, stop and
  restart the node mid leaf build: three-level releases never took the
  span-by-span, resumable tall build, which only the spec and engine-machine
  tests exercise. Take a dispute there through the height-38 leaf seal (an
  even height, so commitment two seals), the step proof and settlement, since
  nothing has run the canonical table node-against-chain. Run it on Linux XFS
  with `reflink=1`, operated from the README by someone who did not write the
  node, and run the harness once on the canonical devnet bundle first (its
  tail adversary's stride must come from the pinned table). Fill a small XFS
  volume once, during a runner batch and during a crossing, and check that
  the node stops cleanly and settles the same root after space returns.
  (computation-hash.md, dispute-game.md)
- Re-derive the reference price on the Linux figures. On v0.23 the runner's
  whole time per input is under the 36 ms threshold on macOS, so inputs
  alone no longer outrun the root join there (the lead above says Linux
  may differ), and the price follows from the next wall: the drain (up to
  2^24 inputs' time, up to 4.4 days of a week at those figures) combined
  with other delays, or the snapshot disk.
  (dimensioning.md, One reference price)
- Have someone who did not write them review the commitment and proof paths
  (engine/ruler.rs, engine/machine_stf.rs, engine/dispute.rs,
  storage/rollups_machine.rs, storage/advance.rs), with computation-hash.md
  as the guide, preferably from the machine team: the budget-seam leaf bug
  of September 2026 was shared by the Lua oracle, so the oracles share blind
  spots. (computation-hash.md)

## Before mainnet funds

- A lead, not assessed: the rollups contracts an application is deployed
  with (`Application`, `ApplicationFactory`, `InputBox`) are built by their
  own release at solc 0.8.30, through the IR with the optimizer on. The
  compiler's bug list has ten entries for 0.8.30, the Yul optimizer one
  fixed in 0.8.38 among them. The release's own suite runs at that
  configuration, so the deployed bytecode is what its authors test. Dave's
  Foundry suites compile the same sources at 0.8.38 and do not run it; e2e
  does. Whether any of the ten touches those contracts is open.
  (plans/audit-readiness.md)
- Rehearse the backstop for an undetected node bug: on a throwaway Sepolia
  application, hold the node out past join closure, let a fabricated claim
  win, and have the guardian foreclose inside the claim staging period. Then
  tell integrators that the staging period must exceed the guardian's
  reaction time, to run two or more nodes on independent providers, to keep
  the sentry set from being all one implementation, and to route the nodes'
  ERROR and restart alerts to the guardian. (epoch-lifecycle.md,
  detection.md)
- Build the detector: the chain-only checks, one tick per scheduled run,
  sharing no code, host or provider with the node. It computes no state. A
  defect every node shares is seen by a second implementation run as a
  validator or a sentry; an independent replay is a lead for where none
  runs. (detection.md)

## Upstream (Cartesi Machine, arm's length: nothing waits on it)

- Ask for a CLI that delivers to a halted template with an input yield
  pending, as the step does (a lead, unverified on v0.23).
  (computation-hash.md)
- Track upstream PR #390 (new pristine uarch hash and proof format) as its own
  coordinated generation. (build-system.md)

## Node

- Before a heavy application runs at a low snapshot gap in production:
  publish a boundary once a batch's executed work reaches the contract's
  replay budget as well as at the gap's count, whichever comes first, so a
  heavy application keeps the default gap and a cheap-input flood keeps one
  snapshot per gap inputs. Append-only and deterministic (the work is the
  machine's mcycle). A count cap that thins old boundaries (about 2^14 per
  epoch) also bounds disk, but adds a deletion path in a live epoch.
  (dimensioning.md, per-input contract)
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
- Have the node say when it is falling behind. The runner logs its rate and
  its backlog with no verdict. With a sealed epoch whose root the node has
  not joined, compare the time the backlog takes at that rate with the time
  left before the root's closure, and log an error once the first exceeds
  the second. (detection.md, node-architecture.md)
- Have the node check its signer against a whole dispute's funding before a
  batch is due. It logs an error only on a tick whose batch reserves more
  than the signer holds, so a balance that covers a root join and not a
  dispute shows once the dispute's clock runs. (detection.md,
  cartesi-rollups/node/README.md)

## Contracts and assurance

- Coordinate reference-node validity: accepted-yield lengths, unknown automatic
  notifications, declared outputs roots and pending accepted yields at the
  cycle boundary. (epoch-lifecycle.md)
- Coordinate reference-node capped epoch rollover: select inputs by sealed
  index bounds, including inputs carried from earlier blocks.
  (epoch-lifecycle.md)
- Review the honest-survival argument (dimensioning.md, "Honest survival
  under the budgets") by someone other than its author, and decide whether
  the searches gate the external audit or are handed over as evidence. The
  second contracts audit re-derived the balance blind and extended the
  search to four levels; that is a second automated reading, not this
  review. (dispute-game.md)
- Re-check the pinned solc (0.8.38) against its bug list at the audit
  freeze; none was listed for it on 2026-11-10. (plans/audit-readiness.md)
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

- Reach the input cap in a node-against-chain or e2e run. The cap is a
  compile-time constant on every side, so it takes a devnet and builds at a
  small one. Sealing at the cap, the last input slot's opening and the last
  stride are pinned below e2e.
  (test-harness.md)
- Move `FOUNDRY_VERSION` to an anvil that does not answer a call pinned to
  the current head from the next block's state, after running the
  pinned-call experiment against it. Until then an e2e player assertion that
  the fold and a view disagree is cleared by a rerun.
  (test-harness.md)
- Identify the reference CLI by package digest instead of its version
  string, which cannot tell the release from its pre-releases or from an
  unreleased upstream build.
  (test-harness.md)
- Optional: a steered divergence point for the harness's tail adversary, to
  dispute active spans in-process. (test-harness.md)
- Two honest nodes on different keys defending one epoch against one
  adversary, in the harness: no test has run two sling nodes at once.
  (test-harness.md)

## Tooling

- The toolchain is off the bare PATH (forge, the CLI and the pinned emulator
  come from the nix devshell): recipes that enter it, or a doctor check that
  names the fix. (build-system.md)
- `just measure-prt-gas` fails its dependency digest with no hint when stale
  dependency directories sit beside the pinned ones (copied rollups-contracts
  alpha.6 and alpha.9): name the extra and missing directories, and let doctor
  check them. (runbooks/prt-refund-gas-calibration.md)

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
- Open: a `--version` flag; the startup line, which names the release tag,
  stands in for it. (node README, operator notes)
