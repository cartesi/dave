# The e2e test harness

The end-to-end tests live in `prt/tests/rollups/` and are orchestrated in
Lua. They spawn the real Rust node binary against a local anvil chain and
attack it with dishonest players. They are the acceptance oracle for any
node refactoring: behavior is pinned at the on-chain-outcome level, not at
the implementation level.

## Anatomy of a test run

```
just rollups-tests::test <program> <script>
  -> lua5.4 test_cases/<script>.lua        (env vars select machine image,
                                            deployment addresses, keys)
```

- `test_env.lua` is the shared fixture. `spawn_blockchain()` starts anvil
  preloaded with the devnet deployment state
  (`cartesi-rollups/contracts/state.json`), deploys the application via
  `DaveAppFactory`, and wires up a `Reader` and `Sender` (thin cast-style
  wrappers in `dave/reader.lua` / `dave/sender.lua`).
- `spawn_node()` launches `target/debug/cartesi-rollups-prt-node` with a
  private-key signer, state dir `_state/`, logs to `dave.log`.
- Dishonest players (sybils) are the honest Lua strategy
  (`prt/client-lua/player/strategy.lua`) driven as a coroutine, with a
  `PatchedCommitmentBuilder` that corrupts chosen leaf hashes at chosen
  levels (`prt/tests/common/runners/`). They play the protocol perfectly
  while defending a wrong commitment - the strongest polite adversary.
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
harness itself (each was hard-earned; see node-audit.md finding 2's
build notes for the discovery stories):

- Every `drive_player_until` poll advances one block: the node
  ingests FINALIZED blocks, so a quiet chain froze its view and
  deadlocked wait-for-the-node loops. One block per second is the
  natural cadence and cannot starve the node's turn.
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
against `_state/db.sqlite3` (the per-epoch dispute databases retired at
sling increment E). All such queries are
centralized in `prt/tests/rollups/dave/node.lua` (`root_commitment`,
`machine_path`, `inputs`). If the node's schema changes, this one file is
the blast radius - treat it as the interface and keep it thin.

The same file owns the process lifecycle: `Dave:kill(signal)` (SIGKILL
by default - crash scenarios deliberately skip graceful shutdown) and
`Dave:respawn()`, which relaunches over the surviving `_state/` and
appends to the same `dave.log`. `Dave:wait_log(pattern, offset)` blocks
until the log matches; `Dave:find_log(pattern, offset)` is the
non-blocking probe for use inside the sybil drive loop. Kill points are
protocol events, not sleeps, so the patterns scenarios rely on are a
stable-marker contract between the node's logging and the harness.
The contract today (a change to any of these lines must update the
scenario that kills on it):

- `processing input <epoch>:<index>` (machine-runner): kill_catchup.
- `computing quartet` (sling cache, dispute-time machine work only,
  since level 0 is served from the frontier fold):
  kill_commitment_build.
- `advance match` (player bisection): kill_mid_match, and the log
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
`yield` (alternates accept/reject), `honeypot` (real application),
`compute` (no-input computation).

Test cases (`prt/tests/rollups/test_cases/`):

- `simple` / `simple_no_input`: honest node settles epochs, with and
  without inputs.
- `big_input`: large input payloads.
- `stf_all`: drives disputes down to on-chain state-transition proofs,
  one transition shape per epoch (see the coverage matrix below).
- `stf_revert`: the full revert restore, the one shape whose position
  must be computed from the oracle at runtime (matrix below).
- `chaos`: the `simple` dispute with the node SIGKILLed and respawned
  on a seeded random cadence throughout (B1 in characterization.md).
  Reproduce a run with `CHAOS_SEED=<seed>`; run it via
  `just test-rollups-chaos`. Qualified 2026-07-02 with five
  consecutive green runs (seeds 1-5, 6-8 kills each); runs in CI with
  a fixed seed.
- `kill_catchup` / `kill_commitment_build` / `kill_mid_match` /
  `kill_settle`: the targeted crash scenarios (B2-B5 in
  characterization.md), each SIGKILLing the node at one log-marked
  moment: mid-input-processing (resume must settle identically to the
  oracle), mid-quartet-computation during a dispute, mid-bisection
  with ten sybil reactions of downtime, and at the settle
  transaction (exactly-once settlement). Run via
  `just rollups-tests::test-kill-all`.
- `kill_catchup_batched`: B2 at snapshot gap 3 - the SIGKILL lands mid
  advance batch, the uncommitted records drop whole, and the resumed
  run must re-execute the batch to the oracle's settlement. The one
  e2e that runs the node above gap 1 (in CI).
- `bad_commitment`: adversary joins with a hand-built garbage commitment.
- `gc_match` / `gc_tournament`: elimination and bond garbage-collection
  paths.
- `multi_sybil`: the permissionless shape (node-audit.md findings
  2/6/7) - honest plus three sybils, two matches live at once, two
  active sybils (one pairing may be sybil-vs-sybil), one silent sybil
  whose match dies by a real on-chain timeout. Doubles as the
  recording source for the concurrent-match/timeout fold fixture
  (RECORD_CHAIN_FIXTURE, tournament_fold.rs).
- `kill_join`: SIGKILL at the hero's join decision (see the marker
  contract above).
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
  ustep + ureset + revert check), reached through idle churn leaves.
- Epoch 2, chain {2^44, 2^28, 3}: plain active ustep (transition 2 of
  input 0), with an interior agree-leaf seal proof.
- Epoch 3, chain {2^48 + 2^44, 2^48 + 2^28, 2^48 + 1}: idle churn
  ustep (the interpreter noticing the machine is yielded), plus the
  divergence-at-position-zero seal (agree state = the level's initial
  hash).
- Epoch 4, chain {2^68 + 2^44, 2^68 + 2^28, 2^68 + 1}: the fused feed
  of input 1 (checkpoint write + input delivery + first ustep) - the
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
suites (prt disputes + stf, consensus); the workspace job runs fmt,
check, and `test-rust-workspace`; the e2e job runs honeypot `simple`,
the batched catch-up kill, chaos at a fixed seed, and honeypot
`stf_all`. Everything else - echo, the full kill battery, chaos seed
sweeps, honeypot-all, yield-all - is manual, which makes it rot-prone
(see the state of the nets below).

There is also a Sepolia smoke setup (`prt/tests/rollups/sepolia/`) that
runs the node against a testnet deployment of the honeypot.

## Known coverage gaps

Recorded here so the characterization effort has a target list;
unverified claims - check before relying on them:

- (closed 2026-07) Crash/restart recovery: B1 chaos plus the B2-B5
  kill scenarios and the batched catch-up kill now cover it.
- (closed 2026-07) Revert transitions at leaf level: `stf_revert`.
- Epochs at capacity boundaries (max inputs, input at the last stride).
- Provider misbehavior: RPC errors, long-range log splits, throttling.
- Multiple honest nodes defending the same epoch concurrently.
- Timeout/clock edge cases from the node's side (the contracts have unit
  tests; the node's reaction to being nearly out of time does not).
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

Runtime is what blocks "everything in CI": the full battery is about
half a day, serial. Drivers, in order: disputes run at production
constants (deep tournaments, hundreds of chain interactions); time
advances by block-stepping and polling; scenarios are serial on fixed
ports. The single biggest lever is the test-shape constants profile
(workstream 8's stated goal): sling's Structure is already
parameterized, the gap is contracts-side, and it would turn dispute
scenarios from minutes into seconds. Second lever: parameterize the
anvil port and state dir so scenarios run in parallel.

Flakiness class to design against: since the 3.0 contracts, an epoch's
input boundary is the InputBox count at the settle transaction's block,
so any assertion about WHICH epoch an input lands in is coupled to node
timing. Assert on content, or control input timing relative to
settlement explicitly (the `big_input` fix chose content-by-
construction: one input total).

Known blind spots, by layer:

- The tournament reader has no tests at all; workstream 5's fold plus
  the chain recordings fix this. Recorded so far: `echo_simple`,
  `multilevel_stf`, and `multi_sybil` (concurrent matches plus a real
  timeout deletion, 2026-07-15).
- (closed 2026-07-09) The Hero's decision table now has a unit
  surface: hero/mod.rs tests drive react_tournament and the GC over
  hand-built DisputeStates and the toy sling source, with a recording
  arena in place of the chain - every arena verb the react loop can
  choose is pinned, including witness shape selection (the toy
  implements the proving verbs with inert marker bytes). E2e remains
  the outer net that checks the chain agrees with these choices.
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

Direction as the rewrite proceeds: shift correctness weight down the
pyramid - fold-from-recordings instead of anvil where possible,
spec.rs-style oracles for each new authority (Position, ruler), and
characterization before each move. E2e remains the outer net, not the
primary one.

## Suite economics (first measurements, 2026-07-09)

Measured on one dev machine (debug node, local anvil) during the
workstream 6 verification run; the first hard numbers behind the
assessment above. Wall times include harness setup but not the
workspace build.

Superseded 2026-07-10 by the full parallel battery (battery.sh: all
21 scenarios, TEST_INSTANCE lanes, ff=128): green scenarios sum to
~41 min of machine time, wall clock ~15 min at 5 lanes. Slowest:
stf_all ~7 min per program, simple_no_input ~3.5 min; the whole kill
family runs 33-129 s; gc_match 46 s. The racy-era "half a day,
serial" figure is retired. That run also caught the second reader
bug (the pruned-pin case study below): the only failures were both
gc_tournament flavors hanging on a dead node until the scenario
deadline failed them - the deadline and the battery each doing
exactly their job.

The clean baseline, same day, after the retry fix and caffeinate:
21/21 green, ~42 min of scenario time, ~11 min wall at 5 lanes, no
leaked processes. gc_tournament runs 80 s on the retried node;
slowest scenario is yield stf_all at ~7 min; the cheapest ten all
finish under two minutes. This is the number to beat, and the run
to repeat before any handoff: LANES=5 prt/tests/rollups/battery.sh.

Sweep the instance dirs once results are read (`just
rollups-tests::sweep`): each lane leaves ~5 GB of forensic state,
two batteries filled a disk to 7 GB free on 2026-07-11, and a
nearly-full disk quietly slowed every 128 MB machine store - the
unit suite crawled from 2 s to 15 s with no code change. `just
doctor` warns when the litter passes 10 GB.

Addendum, same day: the verification battery on the retry-fixed
binary looked catastrophic - four new deadline failures, uniform
~14x dispute slowdowns - and every symptom was the LAPTOP, not the
code: the machine was on battery and cycling into Deep Idle, and
pmset's log matched the lanes' freeze windows to the second (a
608 s sleep = a 607 s simultaneous node+sybil+anvil silence). Zero
retries had fired; the binary was innocent. Three lessons now
encoded: battery.sh holds the machine awake (caffeinate) for the
run; the scenario deadline counts wall clock through sleep, which
is fine once the runner holds the box but must be remembered when
reading unattended failures; and the diagnosis discipline - when
independent processes freeze and resume in lockstep, check
pmset -g log before blaming software. A side probe worth its
numbers: anvil with --preserve-historical-states holds every state
in memory - 8.5 GB at 30k blocks with a superlinear jump past
~12k, vs 4 GB default - so the dump flag pair became opt-in
(ANVIL_DUMP_PATH, unset by default; nothing consumed the dumps).
Real scenarios mine under 1k blocks, where neither config strains.

Second environment incident (2026-07-14): a fresh worktree carried a
STALE devnet - a state.json and deployments deployed from older
contract sources - and the echo e2e died on the node's scariest
assert ("Winner commitment mismatch, notify all users!"), left and
right both plausible hashes. The node, harness, and image were all
innocent; observed on-chain, the stale deployment settled the empty
epoch 0 with the initial machine hash as winner where the current
contracts settle with the joined claim (the padded tree over it).
Diagnosis needed a full bisect run at the
pre-session commit (same failure = environment). Two lessons
encoded: build-devnet now writes state.fingerprint (tree hashes of
both contract packages plus dirty status - script/
devnet-fingerprint.sh), and `just doctor` compares it, naming the
rebuild command; and the diagnosis discipline - when an e2e fails
on a consensus assert in a NEW environment, suspect the deployed
state before the code, and check the sibling worktree's artifacts
byte-for-byte. Copying a green worktree's state.json + deployments
is as valid as copying its machine images (both are deterministic
functions of the sources), and the fingerprint travels with them.

- `echo simple` (full 3-level dispute): ~7 min. Bisection itself is
  fast - advances land 1-2 s apart in bursts; the sybil-active
  window is ~70 s.
- `gc_match` (two lazy sybils, timeout eliminations): ~25 min, of
  which sybil activity is ~1 min. The rest is protocol-time
  fast-forwarding: `wait_until_epoch` advances 16 blocks per 4 s
  poll (FAST_FORWARD_TIME), so every sequential ~300-block clock
  expiry costs ~75 s of wall clock, and timeout-heavy scenarios
  stack several.
- `gc_tournament`: ~5 min (same mechanism, fewer expiries).
- `kill_mid_match`: ~4 min of node-side dispute time with the
  pinned reader (see the case study - the first run took >2 h and
  crashed, and the hours turned out to be the bug, not the test).

Where the wall time goes, by class, largest first: (1) protocol-
timeout fast-forwarding throttled by the harness poll loop
(dominates gc_*, bad_commitment); (2) per-scenario setup and
inter-phase waits (anvil spawn, epoch-0 roll, oracle commitment
builds, settlement polling); (3) serial scenario execution on fixed
ports. Node-side machine work and tick cadence are NOT drivers at
current constants (tests run --sleep-duration-seconds 1; bisection
advances land 1-2 s apart; a full 3-level dispute with a mid-match
kill and catch-up is ~4 min).

Levers, in leverage order:

1. Crank the fast-forward loop: 16 blocks per 4 s is arbitrary
   caution; anvil can advance hundreds of blocks in one call and the
   node at 1 s ticks keeps up. Cheap, harness-only, attacks class 1
   today.
2. Test-shape constants profile (workstream 8): smaller clock
   allowances shrink class 1 at the source, shallower trees shrink
   dispute depth. Contracts-side gap; sling's Structure is ready.
   Note its urgency dropped with the pinned reader: stf_all measured
   ~9 min on 2026-07-09 (all five epochs, four disputes, while
   sharing the machine with a parallel scenario) against the 60 min
   CI budget set in the racy-reader era.
3. (done 2026-07-09) TEST_INSTANCE parallel isolation - wall clock
   for a batch becomes the max of the set, not the sum. Battery
   runners must pick distinct free ports per scenario; since
   2026-07-10 (run-local snapshot scratch) even the same scenario
   twice concurrently is safe, anvil dump paths aside.
4. (done 2026-07-09) Scenario deadline: every wait in the harness and
   Lua client sleeps through utils/time.lua, which now errors loudly
   past SCENARIO_DEADLINE_SECS (default 3600, 0 disables) - a hung
   run fails instead of burning hours. dave.log is archived one
   generation (.prev) so the forensics survive the next run.

Case study, 2026-07-09: the first kill_mid_match run under
workstream 6 ran >2 h with 8-16 minute stalls between node moves,
then crashed - an unpinned overlay read raced the advancing chain
and a clock display underflowed. The stalls and the crash were the
same bug: the tick sampled its block once but point-read at Latest,
so under heavy block traffic the Hero kept seeing inconsistent
fold-vs-position state and concluding "not my turn". Pinning every
read at the tick's block (plus saturating clock arithmetic) fixed
the crash AND cut the scenario to ~4 min. Lessons the numbers
teach: the slow scenario earned its keep (it is the only net that
holds a dispute open long enough, with enough block traffic, to
hit tick-consistency races); when the slowest test is mysteriously
slow, suspect the product before the test (the 2026-07-08
"battery is about half a day" figure was measured on the racy
reader - remeasure before optimizing anything); a dead node
manifests as an infinite hang, not a failure (lever 4); and
per-run log truncation destroyed the first run's evidence (worth
teeing dave.log per run into a scratch dir before rm).

Case study, 2026-07-10 (the pin's other edge): the first full
parallel battery failed exactly two scenarios - both gc_tournament
flavors - each hanging until the new scenario deadline killed it.
The node logs held the cause: a pinned overlay read asked anvil for
state at the tick's sampled block, anvil under aggressive
fast-forward would not serve it (BlockOutOfRangeError), and the
epoch manager's ?-operator turned that transient into node
shutdown - a dead validator with its clocks still running, found
only because the deadline converts hangs to failures. The fix is
architectural, not harness-side: every tick is re-derived from
storage and chain by design, so the epoch manager now logs and
retries failed iterations instead of dying; real gateways prune
historical state too, so this was a production bug wearing a
harness costume. Consensus asserts stay fatal. Lesson: the pinned
read trades tail freshness for consistency, and its price is that
the provider must serve a seconds-old block - degrade to retry,
never to death.

What is NOT earning its keep, on current evidence: the yield-all
tier duplicates honeypot-all's scenario list 1:1 minus
deposit_withdrawal (simple_no_input, stf_all, big_input, gc_match,
gc_tournament, bad_commitment) - the program differs but the
protocol paths exercised are the same. Yield's unique value is the
revert shape, and that lives in stf_revert - which, as discovered
while writing this, was wired into NO suite target and no CI step
(now in test-yield-all): the full-revert-restore net had been dark
since it was written, the exact big_input rot pattern. A reasonable
nightly tier keeps yield stf_revert and drops the duplicated yield
scenarios to manual; verify the overlap claim per scenario before
acting.

The unit-layer counterpart landed the same day (see the blind-spot
list): the Hero is generic over the ruler factory, the toy grew
proving verbs, and thirteen decision-table tests run the react loop
chain-free in a fraction of a second. Still open from that recipe:
the reader's overlay assembly against a mock provider.

## Adding a scenario

1. Pick or build a machine program under `test/programs/` (see its
   justfile; images are built with the `cartesi-machine` CLI).
2. Write `prt/tests/rollups/test_cases/<name>.lua`: require `test_env`,
   spawn blockchain and node, drive epochs with `run_epoch` or hand-rolled
   sybils with patch lists.
3. Wire a justfile alias if it should run in a suite
   (`prt/tests/rollups/justfile`).
