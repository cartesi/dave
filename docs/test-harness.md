# The e2e test harness

The end-to-end tests live in `test/e2e/rollups/` and are orchestrated in
Lua. They spawn the real Rust node binary against a local anvil chain and
attack it with dishonest players. They are the acceptance oracle for any
node refactoring: behavior is pinned at the on-chain-outcome level, not at
the implementation level.

This is distinct from the Solidity and Foundry test architecture under
`prt/contracts`, documented in
[`prt-contract-testing.md`](prt-contract-testing.md).

## Anatomy of a test run

```
just rollups-tests::test <program> <scenario>
  -> lua5.4 scenarios/<scenario>.lua       (env vars select machine image,
                                             deployment addresses, keys)
```

- `test_env.lua` is the shared fixture. `spawn_blockchain()` starts anvil
  preloaded with the devnet deployment state
  (`cartesi-rollups/contracts/state.json`), deploys the application via
  `DaveAppFactory`, and wires up a `Reader` and `Sender` (thin cast-style
  wrappers in `dave/reader.lua` / `dave/sender.lua`).
- `spawn_node()` launches `target/debug/cartesi-rollups-prt-node` with a
  private-key signer, state dir `_state/`, and logs to `dave.log`. Under
  `TEST_INSTANCE=<id>`, the state and log become `_state-<id>/` and
  `dave-<id>.log`.
- Dishonest players (sybils) drive the Lua semantic actor
  (`prt/client-lua/player/actor.lua`) as a coroutine. Its independent
  structural fold, strict ABI decoding boundary, domain context, pure planner,
  fulfiller, and dispatcher exercise the same protocol decisions without
  sharing expected values. A `PatchedCommitmentBuilder` corrupts chosen leaf
  hashes at chosen levels (`test/e2e/support/runners/`). The sybils play the
  protocol perfectly while defending a wrong commitment - the strongest polite
  adversary. The honest Lua fulfiller rejects a machine post-state that differs
  from its claim by default. Only the sybil runner enables the explicit
  `allow_invalid_claims` harness mode: it submits the valid machine transition
  proof against the deliberately wrong claim so the contract rejection and
  adversarial clock path remain exercised.
- Time is driven manually: the harness advances anvil blocks
  (`advance_blocks`) and sleeps until the node reacts, so wall-clock
  timeouts in the protocol become block-count fast-forwards.
- `Env.run_epoch(sealed_epoch, patches, next_inputs)` is the main driver:
  compute the honest settlement independently in Lua, spawn a patched
  sybil, drive it until it loses, wait for settlement, assert the honest
  commitment won.

## The self-anchored oracle

`Env.epoch_settlement` maintains an independent machine lineage (the
oracle): it starts from the template machine, replays only chain inputs,
and advances epoch after epoch under `_oracle/`. Every epoch it verifies
the chain anchor (the `EpochSealed` event's initial state equals the
lineage state) and then cross-checks the node: inputs against chain
events, the node's epoch snapshot against the lineage state, the node's
commitment against the oracle's. Sybils build their commitments from
oracle-owned epoch snapshots. Node output is never an input to the
oracle, only a subject of comparison. Keep this property through any
rewrite; it is what makes the e2e suite fit to judge one.

## Trust bases of the assertions

What each assertion family ultimately trusts (chain = anvil events and
calls; oracle = the independent Lua lineage; node = the subject under
test, never a source):

- Epoch inputs: chain events; node database inputs are cross-checked.
- Epoch initial state: oracle lineage, anchored to the EpochSealed
  event; the node's snapshot is loaded and cross-checked against it.
- Epoch commitment: oracle lineage; the node's commitment (read from
  its database) is cross-checked against it.
- Sybil machine material: oracle epoch snapshots.
- Tournament winners and settlement: chain state, compared against the
  oracle commitment.
- Node reads (`dave/node.lua`) serve synchronization (wait until the
  node has progressed) and produce the cross-check subjects.

Residual risk, by design: a conceptual bug shared by the Lua oracle and
the Rust node is invisible to these checks except where a dispute
reaches the on-chain state transition. The sling differential chain
(toy spec, reference collector, prototype fixtures) mitigates from the
other side.

## Hardened primitives (2026-07-16)

Operational traps that used to be folklore are now enforced by the
harness itself. Each rule below closes a reproduced harness failure:

- Every `drive_player_until` poll advances one block. Epoch discovery still
  progresses through finalized ingestion; once an epoch is discovered, its
  tournament reader also acts on a disposable latest tail. One block per
  second is the natural cadence and cannot starve the node's turn.
- `Env.fast_forward(blocks)` is the clock-safe scenario
  fast-forward: it sleeps first so the node's pending move lands,
  then advances. Bulk advances between the node's one-second ticks
  burn its block-denominated chess clock while on turn (observed: an
  honest node timed out of its own dispute at 128 blocks per idle
  poll). Keep chunks small while a dispute is live.
- Sybils auto-allocate distinct signing accounts (from 2 up;
  account 1 is the honest node's and is refused): two sybils sending
  concurrently on the old shared default wedged on nonces, and every
  serial scenario had silently gotten away with it.
- `battery.sh` takes LANES as its first argument (`./battery.sh 5` -
  no `direnv exec . env LANES=5` incantation), warns at start when on
  battery power, and records power provenance in _battery/power.txt
  alongside the existing mid-run sleep tripwire.
- `just check` preflights docker (script/ensure-docker.sh): the kms
  testcontainers fail confusingly under a sleeping Docker Desktop,
  which the preflight wakes on macOS and names elsewhere.

## Node introspection seam

The harness reads the node's internal state by shelling out to `sqlite3`
against `_state/db.sqlite3`; the node no longer has per-epoch dispute
databases. All such queries are
centralized in `test/e2e/rollups/dave/node.lua` (`root_commitment`,
`machine_path`, `inputs`). If the node's schema changes, this one file is
the blast radius - treat it as the interface and keep it thin.

The same file owns the process lifecycle: `Dave:kill(signal)` (SIGKILL
by default - crash scenarios deliberately skip graceful shutdown) and
`Dave:respawn()`, which relaunches over the surviving state and appends
to the same instance-specific node log. `Dave:wait_log(pattern, offset)`
blocks until the log matches; `Dave:find_log(pattern, offset)` is the
non-blocking probe for use inside the sybil drive loop. Kill points are
protocol events, not sleeps, so the patterns scenarios rely on are a
stable-marker contract between the node's logging and the harness.
The contract today (a change to any of these lines must update the
scenario that kills on it):

- `processing input <epoch>:<index>` (machine-runner): kill_catchup.
- `computing quartet` (sling cache, dispute-time machine work only,
  since level 0 is served from the frontier fold):
  kill_commitment_build.
- `advance match` (Hero dispatch): kill_mid_match, and the log
  line the suites grep to observe dispute progress.
- `settle epoch` (epoch-manager, logged before the accept
  transaction - the settlement-finalizing step of the staged
  protocol): kill_settle. Staging and sentry claims happen in
  earlier ticks; a kill-at-stage scenario is an open lead.
- `join tournament` (hero, logged as it decides to join): kill_join -
  the join transaction may or may not have landed when the kill hits,
  and the respawn must end up joined exactly once.

## Scenario inventory

Machine programs (`test/programs/`): `echo` (accepts and rejects inputs),
`yield` (awaits each input with `RX_ACCEPTED`, then rejects it with
`RX_REJECTED`), `honeypot` (real application),
`compute` (no-input computation; buildable but not yet wired into any
scenario).

Scenarios (`test/e2e/rollups/scenarios/`):

- `simple` / `simple_no_input`: honest node settles epochs, with and
  without inputs.
- `big_input`: large input payloads.
- `stf_all`: drives disputes down to on-chain state-transition proofs,
  one transition shape per epoch (see the coverage matrix below).
- `stf_revert`: the full revert restore, the one shape whose position
  must be computed from the oracle at runtime (matrix below).
- `chaos`: the `simple` dispute with the node SIGKILLed and respawned
  on a seeded random cadence throughout.
  Reproduce a run with `CHAOS_SEED=<seed>`; run it via
  `just test-rollups-chaos`. Qualified 2026-07-02 with five
  consecutive green runs (seeds 1-5, 6-8 kills each); runs in CI with
  a fixed seed.
- `kill_catchup` / `kill_commitment_build` / `kill_mid_match` /
  `kill_settle`: the targeted crash scenarios, each SIGKILLing the node at one
  log-marked moment: mid-input-processing (resume must settle identically to the
  oracle), mid-quartet-computation during a dispute, mid-bisection
  with ten sybil reactions of downtime, and at the settle
  transaction (exactly-once settlement). Run via
  `just rollups-tests::test-kill-all`.
- `kill_catchup_batched`: B2 at snapshot gap 3 - the SIGKILL lands mid
  advance batch, the uncommitted records drop whole, and the resumed
  run must re-execute the batch to the oracle's settlement. This is the
  focused gap-3 case; other scenarios default to gap 2.
- `bad_commitment`: adversary joins with a hand-built garbage commitment.
- `gc_match` / `gc_tournament`: elimination and bond garbage-collection
  paths.
- `multi_sybil`: the permissionless shape - honest plus three sybils, two
  matches live at once, two active sybils (one pairing may be sybil-vs-sybil),
  one silent sybil
  whose match dies by a real on-chain timeout.
- `kill_join`: SIGKILL at the hero's join decision (see the marker
  contract above).
- `sealed_leaf_timeout_winner` / `sealed_leaf_timeout_both`: construct
  unequal leaf clocks, assert the semantic timeout view at exact boundaries,
  then respawn the Rust node and require either the longer-clock winner or
  double elimination.
- `deposit_withdrawal` (honeypot): application-level end-to-end flow.

## Steering disputes: patch chains

A sybil patch `{ hash, meta_cycle = M }` garbles the leaf whose
post-state sits at meta-cycle M, i.e. the result of transition M - 1.
Two rules govern where it bites (`patched_commitment.lua`):

- A patch applies only at levels where M is stride-aligned, so a
  mid-span M never changes the coarse commitments.
- The dispute descends through the EARLIEST divergent leaf of each
  level, so only the smallest effective patch of each level's span
  shapes the descent.

Steering a dispute onto transition M - 1 therefore takes a chain of
three patches: the enclosing level-0 leaf boundary, the enclosing
level-1 leaf boundary, and M itself. The rules make chains
self-consistent: each boundary patch is also the last leaf of the
level below, so the sybil's levels stay mutually coherent. A boundary
M is its own (degenerate) chain. Beware the historical trap this
paragraph replaces: pre-rewrite `stf_all` carried unaligned extra
patches that never applied, so all its epochs actually verified the
same closing-slot shape in window 0 - which is how both increment-C
bugs (idle churn, window-1 counter overflow) stayed invisible to e2e.

Coverage matrix (`stf_all`, one dispute driven to the on-chain state
transition per epoch):

- Epoch 1, chain {2^44}: closing slot of an idle big cycle (final
  ustep + ureset), reached through idle churn leaves.
- Epoch 2, chain {2^44, 2^28, 3}: plain active ustep (transition 2 of
  input 0), with an interior agree-leaf seal proof.
- Epoch 3, chain {2^48 + 2^44, 2^48 + 2^28, 2^48 + 1}: idle churn
  ustep (the interpreter noticing the machine is yielded), plus the
  divergence-at-position-zero seal (agree state = the level's initial
  hash).
- Epoch 4, chain {2^68 + 2^44, 2^68 + 2^28, 2^68 + 1}: the fused feed
  of input 1 (input delivery with revert root + first ustep) - the
  only dispute past window 0, so replays cross a fed input boundary.

The full revert restore is pinned by `stf_revert` (yield program,
which rejects every input): its position is program-timing-dependent,
so the oracle reports each input's big-cycle count
(`settlement.processing_bigs`, captured at the yield before the revert
reloads the snapshot) and the scenario computes the chain at runtime,
aiming at the closing slot of the big cycle where the reject yielded.
`run_epoch` accepts a function in place of a patch list for exactly
this. Not yet pinned: capacity boundaries (last input slot, last
stride).

CI (`.github/workflows/build.yml`): the contracts jobs run the forge
suites (prt disputes + stf, consensus); the workspace job runs Rust fmt
and check, Clippy, Lua lint and client unit tests, the Rust build, and
`test-rust-workspace`; the e2e job runs honeypot `simple`, the batched
catch-up kill, chaos at a fixed seed, and honeypot `stf_all`. Everything
else - echo, the full kill battery, chaos seed sweeps, honeypot-all, and
yield-all - is manual, which makes it rot-prone (see the state of the
nets below).

There is also a legacy Sepolia smoke setup (`test/e2e/rollups/sepolia/`).
It is retained as a lead, but is not part of current CI and has not been
revalidated by this harness maintenance.

## Known coverage gaps

Recorded here so the characterization effort has a target list;
unverified claims - check before relying on them:

- (closed 2026-07) Crash/restart recovery: B1 chaos plus the B2-B5
  kill scenarios and the batched catch-up kill now cover it.
- (closed 2026-07) Revert transitions at leaf level: `stf_revert`.
- Epochs at capacity boundaries (max inputs, input at the last stride).
- Provider misbehavior: RPC errors, long-range log splits, throttling.
- Multiple honest nodes defending the same epoch concurrently.
- (closed 2026-07-25) Sealed-leaf timeout boundaries from the node's side:
  `sealed_leaf_timeout_winner` observes the longer clock winning after the
  retired midpoint and before its own deadline; `sealed_leaf_timeout_both`
  observes double elimination at exact equality. The maintained contract phase
  table lives in [`dispute-game.md`](dispute-game.md); these scenarios retain
  the executable client boundary evidence.
- (closed 2026-07-09) Port hygiene: the free-port assert (2026-07-02)
  plus TEST_INSTANCE isolation - set it to a free port and the run
  gets its own anvil port and suffixed working-dir singletons
  (_state-<id>, dave-<id>.log, anvil-<id>.log, _oracle-<id>,
  _machine_scratch-<id>), so scenarios run in parallel. The last
  caveat fell 2026-07-10: the machine wrapper's snapshot scratch
  moved from beside the source image to the run-local (and
  instance-suffixed) _machine_scratch, cleared at scenario start, so
  parallel runs of even the same scenario no longer share snapshot
  state.

## State of the nets (assessment, 2026-07-08)

Written after running the full battery over the storage v2 reshape;
opinions, not just inventory. The individual layers are healthy - the
system-level risks are tiering and runtime.

What to preserve at all costs: the oracle doctrine (the node is the
subject, never the source; independent lineages compared), seeded
reproducible chaos, log-marker kill points, and reviewed-regeneration
fixtures. These caught real consensus-relevant bugs; they are the
harness's identity.

The structural risk is that correctness weight sits in the slowest,
least-run layer, and suites outside the loop rot. Case study:
`big_input` broke when the 3.0 contracts changed epoch sealing and
stayed broken until 2026-07-08, because honeypot-all runs in nobody's
loop. The response was to move the two highest-value uncovered nets
into CI (stf_all, the batched kill) - but the durable fix is explicit
tiers: per-PR CI (fast, always), nightly (full battery, chaos seed
sweeps), manual (measurement regeneration). A suite not assigned to a
tier should be treated as deleted.

Runtime remains the reason not everything belongs in per-PR CI. Parallel
`TEST_INSTANCE` lanes retired the fixed-port bottleneck after this assessment;
the current baseline, drivers, and remaining levers are in Suite economics
below.

Flakiness class to design against: since the 3.0 contracts, an epoch's
input boundary is the InputBox count at the settle transaction's block,
so any assertion about WHICH epoch an input lands in is coupled to node
timing. Assert on content, or control input timing relative to
settlement explicitly (the `big_input` fix chose content-by-
construction: one input total).

Known blind spots, by layer:

- (current 2026-08-09) The Rust tournament reader's focused suite covers the
  recursively owned `Dispute`, block-grouped local transitions, dynamic child
  discovery and descriptor enrichment, strict event decoding, finalized Solid
  plus disposable Foam, and the one-way narrow observer boundary. The retired
  Campaign 1 chain-recording oracle encoded the old event ABI and was removed
  with the legacy Rust fold; current event parity belongs to the Solidity, Lua,
  recursive-reader, and end-to-end suites.
- (Campaign 1, closed 2026-07-24) The tournament reader had focused tests for
  durable finalized-prefix plus disposable number-range tail assembly, global
  log ordering, dynamic child discovery, finalized-boundary validation,
  watermark discipline, persistence despite latest sampling, live-tail fetch,
  or semantic failures, and semantic reads pinned to a sampled hash without
  requiring canonicality.
  Recorded folds covered `echo_simple`, `multilevel_stf`, and `multi_sybil`
  (concurrent matches plus a real timeout deletion).
- (closed 2026-07-24) Hero policy, context assembly, fulfillment, dispatch, and
  GC are separate unit surfaces. Table-driven planner tests cover terminal,
  join, timeout, phase, and recursive-child decisions; action tests cover
  proof/opening preparation; the recording sender proves that each prepared
  variant invokes exactly one mutation. E2e remains the outer net that checks
  the contracts agree with those choices.
- (Campaign 1, closed 2026-07-24) The Lua sybil path used the same semantic
  observation boundary as the Rust node through an independent implementation.
  Its provider-free suite covered domain invariants, the structural fold,
  strict ABI adaptation, exact-head reading, context assembly, pure Hero and GC
  planning, fulfillment, and one-action dispatch. The focused `gc_match`,
  `gc_tournament`, and `multi_sybil` scenarios are the cross-process evidence
  for match cleanup, recursive cleanup, and concurrent live matches.
- The fail-closed observation rule from that campaign remains applicable: if
  timeout status and its phase projection disagree despite being pinned to the
  same head, reject the whole observation. Retain the raw RPC responses,
  address, arguments, calldata, and pinned head; never retry or normalize the
  two reads into apparent coherence.
- The e2e battery runs the node at snapshot gap 2 by default (since
  2026-07-13; it ran gap 1 before). At gap 1 three node paths were
  dark in every scenario: the non-boundary GC's modulo never fired,
  advance batches degenerated to single inputs, and dispute
  positioning never replayed past a boundary. Gap 2 lights all three
  everywhere at the cost of at most one input of replay;
  `kill_catchup` pins gap 1 for the degenerate case and
  `kill_catchup_batched` runs gap 3.
- The storage unit tests build a real 128 MB machine per test from
  `test/programs/linux.bin`: filesystem and emulator dependencies in
  what should be unit tests, plus bootstrap friction on fresh
  worktrees. (Measured 2026-07-11: all sites together cost ~1.4 s,
  so the once-built template was dropped as not worth shared state;
  the dependency-hygiene point stands. The unit suite's real cost
  was three blockchain_reader tests waiting out anvil interval
  mining and 1 s polls; they are event-driven now - automine plus
  explicit anvil_mine to advance finality - and the whole lib suite
  runs in under 2 s.)
- Harness hygiene: the `_oracle` cleanup warnings. (The machine
  wrapper's snapshot-litter default was fixed 2026-07-10: snapshots
  now default to the run-local `_machine_scratch` - see
  `computation/machine.lua`; test/programs/.gitignore keeps the old
  litter pattern shielded as a belt-and-suspenders.)

Direction after the recursive-reader rewrite: keep correctness weight down the
pyramid. Prefer pure `Dispute` transition tests, strict observer DTO tests, and
compact provider recordings for recursive block loads before reaching for
anvil. Keep spec-style oracles for each new authority and characterize behavior
before each move. E2e remains the outer net, not the primary one.

## Suite economics

The dated measurement narrative and incident case studies behind this
section are frozen in
[`reviews/2026-07-09-e2e-suite-economics/`](reviews/2026-07-09-e2e-suite-economics/README.md);
what follows is the living summary.

The baseline to beat (2026-07-10, retry-fixed binary, caffeinated):
all-green battery, ~42 min of scenario time, ~11 min wall at 5 lanes,
no leaked processes. The run to repeat before any handoff:
`LANES=5 test/e2e/rollups/battery.sh`. Sweep the instance dirs once
results are read (`just rollups-tests::sweep`): each lane leaves ~5 GB
of forensic state, and a nearly-full disk quietly slows every machine
store; `just doctor` warns when the litter passes 10 GB.

Where the wall time goes, by class, largest first: (1) protocol-timeout
fast-forwarding throttled by the harness poll loop (dominates gc_*,
bad_commitment); (2) per-scenario setup and inter-phase waits (anvil
spawn, epoch-0 roll, oracle commitment builds, settlement polling).
Node-side machine work and tick cadence are NOT drivers at current
constants. Parallel `TEST_INSTANCE` lanes already remove serial
fixed-port execution from the wall-time model.

Levers: the fast-forward crank (ff=128), TEST_INSTANCE parallel
isolation, and the loud scenario deadline are done and default. Still
open: the test-shape constants profile (smaller clock allowances and
shallower trees would shrink protocol-time fast-forwarding at the
source; contracts-side gap, the engine's Structure is ready) - its
urgency dropped once the pinned reader landed.

Open tiering recommendation, on current evidence: the yield-all tier
duplicates honeypot-all's protocol paths 1:1 minus deposit_withdrawal;
yield's unique value is the revert shape in stf_revert. A reasonable
nightly tier keeps yield stf_revert and drops the duplicated yield
scenarios to manual - verify the overlap claim per scenario before
acting.

Diagnosis disciplines the incidents taught (details in the frozen
record):

- When independent processes freeze and resume in lockstep, check
  `pmset -g log` before blaming software; battery.sh holds the machine
  awake for exactly this reason.
- A stale devnet once surfaced as a misleading consensus assert in a new
  environment. The e2e preflight now verifies the recorded inputs, state,
  and deployments before Lua or the node starts; `just doctor` reports the
  same failure and names the rebuild command.
- When the slowest test is mysteriously slow, suspect the product
  before the test; remeasure before optimizing anything.
- A dead node manifests as an infinite hang, not a failure; the
  scenario deadline exists to convert hangs into failures. It counts
  wall clock through sleep - remember that when reading unattended
  failures.
- Pinned reads trade tail freshness for consistency, and the price is
  that the provider must serve a seconds-old block: degrade to retry,
  never to death. Consensus asserts stay fatal.
- The log-marker contract is behavioral test infrastructure, not
  incidental prose: a refactor that drops a stable marker silently
  disarms the kill-point scenarios that depend on it.

## Adding a scenario

1. Pick or build a machine program under `test/programs/` (see its
   justfile; images are built with the `cartesi-machine` CLI).
2. Write `test/e2e/rollups/scenarios/<name>.lua`: require `test_env`,
   spawn blockchain and node, drive epochs with `run_epoch` or hand-rolled
   sybils with patch lists.
3. Wire a justfile alias if it should run in a suite
   (`test/e2e/rollups/justfile`).
4. Add it to `battery.sh`'s `SCENARIOS` array if it should run in the
   full parallel battery - the array is independent of the justfile
   aliases and does not inherit from them. If it is deliberately excluded,
   add its bare script name to `EXCLUDED_SCENARIOS` and put the reason in an
   adjacent comment.
