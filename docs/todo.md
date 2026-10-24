# To-do

The one live list of agreed work. An item is one or two lines: the work, a
clause of why, and the living doc that owns its reasoning. A done item is
deleted; the commit that lands it updates the owner doc. Dated review records
carry no backlog (reviews/README.md).

## Before the audited release

- Confirm `[38, 0]` / `[54, 38]` at `T = 120` on validator-grade hardware
  (measured on one M5 Max laptop, v0.21.0; re-measure on v0.22, whose uarch
  changed); the per-input compute contract
  and the worst-case leaf proof plus fallback latency (CF-01, one shared
  `G` for both landings) follow from it, and re-measure the heaviest
  instruction's usteps while there. Time one root response and one leaf
  build while a runner batch of stress inputs runs (the two share cores with
  no priority), and count one re-preparation of a leaf proof still pending
  at the next tick in the fallback latency. Measure on Linux XFS on a cloud
  volume, since every figure so far is APFS and a Linux clone writes back
  the source's dirty pages first: the per-input overhead on the emulator
  release that fixes the cold hash-tree cache read (about 150 ms on macOS
  with v0.22.0; time it on local NVMe and on the cloud volume at baseline
  provisioning), the clone's latency and bytes written per input with a
  dirty source, the runner's sustained inputs per second for accepted,
  rejected and alternating inputs (a fixture that rejects by payload), and
  the disk per snapshot at the default gap. The default gap and the
  aggregate-throughput price follow from them.
  (measurements/constants.md, dimensioning.md)
- Decide how much of C one input flood may drain, then price input volume
  against that root-join window. The input cap protects coordinates and a
  fast enough runner; it does not give notice before a seal or bound backlog
  delay. (dimensioning.md)
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
- Have someone who did not write them review the commitment and proof paths
  (engine/ruler.rs, engine/machine_stf.rs, engine/dispute.rs,
  storage/rollups_machine.rs, storage/advance.rs), with computation-hash.md
  as the guide, preferably from the machine team: the budget-seam leaf bug
  of September 2026 was shared by the Lua oracle, so the oracles share blind
  spots. (computation-hash.md)

## Before mainnet funds

- Rehearse the backstop for an undetected node bug: on a throwaway Sepolia
  application, hold the node out past join closure, let a fabricated claim
  win, and have the guardian foreclose inside the claim staging period. Then
  tell integrators that the staging period must exceed the guardian's
  reaction time, run two or more nodes on independent providers as sentries,
  and route their ERROR and restart alerts to the guardian. (epoch-lifecycle.md)

## Upstream (Cartesi Machine, arm's length: nothing waits on it)

- Ask for a hash-tree parallelism threshold based on work, not core count;
  corpus vectors at both input-budget seams with later inputs; a collector
  assert for a non-pristine uarch; and a CLI that delivers to a halted
  template with an input yield pending, as the step does (a lead).
  (computation-hash.md)
- On the emulator release that fixes the cold load of the hash-tree cache
  file (in progress upstream, not a blocker: about 2.5 ms per input in a
  preliminary implementation, with validation on an untrusted load), bump
  the emulator and re-measure the per-input overhead and the reference
  price. Check whether that validation is the supported `cm_verify_hash_tree`
  the item below waits on (a lead). (node-architecture.md, Storage)
- Ask for EMLINK in `os::clone_file`'s copy fallback, low priority: a clone
  hard-links every read-only file (each snapshot's PMA file), so on btrfs and
  ext4 live snapshots stop at about 65k links per inode, and the runner and
  positioning stall there. XFS, the one production filesystem, makes it
  unreachable. (node README, filesystem)
- Track upstream PR #390 (new pristine uarch hash and proof format) as its own
  coordinated generation. (build-system.md)
- On the emulator release that supports `cm_verify_hash_tree` (v0.22.0 has
  it for internal tests only, unoptimized, and the emulator team asked that
  nothing call it there): bump the emulator, uncomment the binding and its
  test in the cartesi-machine crate and the check in `Template::inspect`,
  un-ignore that check's test, and drop the notes that say to trust a seed
  image's source, since the node takes the image's root from its stored hash
  tree. (node-architecture.md)

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

## Contracts and assurance

- Coordinate reference-node validity and capped epoch rollover: accepted-yield
  lengths, unknown automatic notifications, declared outputs roots, pending
  accepted yields at the cycle boundary, and input selection by sealed index
  bounds. (epoch-lifecycle.md)

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
- Open: a `--version` flag; the startup line, which names the release tag,
  stands in for it. (node README, operator notes)
