# The e2e test harness

The end-to-end tests live in `test/e2e/rollups/` and are orchestrated in
Lua. They spawn the real Rust node binary against a local anvil chain and
attack it with dishonest players. They are the acceptance oracle for any
node refactoring: behavior is pinned at the on-chain-outcome level, not at
the implementation level.

This is distinct from the Solidity and Foundry test architecture under
`prt/contracts`, documented in
[`prt-contract-testing.md`](prt-contract-testing.md), and from the node's
in-crate harness (`cartesi-rollups/node/src/harness/`, `just
test-node-harness`), which drives the node's own workers tick by tick against
a deterministic anvil and is where lifecycle and dispute scenarios move as the
e2e suite shrinks.

## What each layer establishes

- Solidity: Foundry only (prt-contract-testing.md). The step tests run a
  real machine through FFI; no node is involved.
- The node's computation: correct hashes and proofs, built in time with
  bounded memory and disk, in two regimes. Eager: the runner executes an
  open epoch, samples at the root stride, folds window roots and keeps
  snapshots. Lazy: a dispute positions from snapshots and builds quartets,
  leaves and proofs. Unit and toy-spec tests, the real-machine
  differentials and goldens (`tests/engine_machine.rs`) and the work counts
  cover it; the node-versus-emulator recipe measures time, RSS and disk.
- The node's workers against a chain: the in-crate anvil harness
  (`src/harness/`, `just test-node-harness`): the sender, the epoch
  lifecycle (settle, stage, cleanup, bond recovery), the Hero against
  adversaries, restarts and timeouts, with the test owning the clock.
- End to end (this document): only what needs the node as a process, real
  signals and an independent Lua lineage.

## Anatomy of a test run

```
just e2e <program> <scenario>              (builds the node first)
  -> just rollups-tests::test <program> <scenario>   (preflight)
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
  commitment won. It returns the next sealed epoch and the dispute's sealed
  leaf matches (tournament, match ID hash, transition). It does not check
  how they were resolved, since kill and chaos runs may legitimately end a
  leaf match on a timeout.
- `Env.assert_leaf_match_proved(tournament, match_id_hash)` requires exactly
  one `MatchDeleted` for the match, with reason `STEP`. A timeout win leaves
  the same seal and the same settlement behind, so only this shows that the
  on-chain state transition resolved the match.
- `Env.run_steered_epoch(sealed_epoch, transition, next_inputs)` steers the
  dispute onto one transition (see "Steering disputes") and asserts that
  exactly one leaf match sealed there and a STEP proof resolved it.

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

The reference implementation, the released v0.21.0 `cartesi-machine` CLI,
no longer gates every e2e epoch: its answers are checked below e2e, where the
node's runner, leaves and the release corpus are compared with it
(`cartesi-rollups/node/tests/engine_machine.rs`, `just
test-reference-cli-goldens`).

## Trust bases of the assertions

What each assertion family ultimately trusts (chain = anvil events and
calls; oracle = the independent Lua lineage; node = the subject under
test, never a source):

- Epoch inputs: chain events; node database inputs are cross-checked.
- Epoch initial state: oracle lineage, anchored to the EpochSealed
  event; the node's snapshot is loaded and cross-checked against it.
- Epoch commitment: oracle lineage; the node's commitment (read from its
  database) is cross-checked against it.
- Sybil machine material: oracle epoch snapshots.
- Tournament winners and settlement: chain state, compared against the
  oracle commitment.
- Settlement machine validity: `Env.roll_epoch` waits for the next
  `EpochSealed`, which can follow only after DaveConsensus accepts the staged
  final-state proof and its TX-buffer outputs root.
- Node reads (`dave/node.lua`) serve synchronization (wait until the
  node has progressed) and produce the cross-check subjects.

Residual risk, by design: a conceptual bug shared by the Lua oracle and the
Rust node is invisible to these checks except where a dispute reaches the
on-chain state transition. Below e2e, `runner_settles_the_reference_root`
(`cartesi-rollups/node/tests/engine_machine.rs`) checks the production
runner's settled root against checked-in answers of the release CLI under
both tables (the root samples every 2^(stride - 20) big cycles; at 2^17 a
sample falls inside echo's rejected input, so the revert shows), and
`leaf_commitments_match_the_reference_cli` checks stride-0 leaf commitments
(dense spans, yields, reverts) against the CLI's uarch cycle computation
hashes at periods 7 and 8. The node builds dense leaves with the emulator's
collector, as the CLI does, so those leaves and the corpus's are also built
with the node's stepped reference, `bulk_and_stepped_leaf_runs_agree`
compares the two per big cycle, and `uarch_bundles_reduce_to_the_unbundled_leaves`
ties the collector's bundling to the node's Merkle assembly. The sling
differential chain (toy spec, reference collector, prototype fixtures)
mitigates from the other side.

## Hardened primitives (2026-07-16)

Operational traps that used to be folklore are now enforced by the
harness itself. Each rule below closes a reproduced harness failure:

- Every `drive_player_until` poll advances one block. Epoch discovery still
  progresses through finalized ingestion; once an epoch is discovered, its
  tournament reader also acts on a disposable latest tail. One block per
  second is the natural cadence and cannot starve the node's turn.
- Never bulk-advance blocks while a dispute is live: advances between
  the node's one-second ticks burn its block-denominated chess clock
  while it is on turn (observed: an honest node timed out of its own
  dispute at 128 blocks per idle poll). Advance through
  `drive_player_until`; big jumps are safe only when no match awaits
  the node's move (`wait_until_epoch`'s settlement polling).
- Sybils auto-allocate distinct signing accounts from 2 up, skipping the
  node's (`node_pk` in `test/e2e/support/blockchain/constants.lua`);
  account 1 is the harness sender's. Two senders on one account wedge on
  nonces.
- `just test-kms` preflights docker (script/ensure-docker.sh): the kms
  testcontainers fail confusingly under a sleeping Docker Desktop,
  which the preflight wakes on macOS and names elsewhere. They are the only
  Rust tests that need docker, so they sit outside `just check`.

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
The contract today (a change to this line must update the scenario that
kills on it): `processing input <epoch>:<index>` (machine-runner):
kill_catchup_batched. The other targeted kills moved below e2e: at the join,
mid-bisection and around acceptance to the node's in-crate harness
(`restart_after_*`), which restarts the workers deterministically instead of
signalling, and mid-build to the unit test
`restarted_source_resumes_a_half_built_level` (`tests/engine_machine.rs`).

## Scenario inventory

Machine programs (`test/programs/`): `echo` (accepts and rejects inputs),
`yield` (awaits each input with `RX_ACCEPTED`, then rejects it with
`RX_REJECTED`), and `honeypot` (real application; an opt-in image outside
CI, built from any honeypot commit, see `test/e2e/rollups/README.md`). The
explicit `stress` image belongs to the Rust measurement workflow, not to an
E2E scenario.

Scenarios (`test/e2e/rollups/scenarios/`), the black-box smoke left after
the 2026-10-01 cut:

- `simple`: the honest node settles a disputed epoch. Its one leaf match
  must end in a STEP proof (`Env.assert_leaf_match_proved`), so the per-PR
  echo `simple` and the two-level smoke gate the on-chain state
  transition. The gate's negative control (a timeout-resolved leaf refused)
  left with the sealed-leaf scenarios; the per-PR STEP evidence no longer
  rests on it alone: the node harness requires the node's `winLeafMatch` at
  a closing slot to mine, and `NodeWitnessesTest` replays the node's bytes.
- `stf_all`: drives disputes down to on-chain state-transition proofs,
  one transition shape per epoch (see the coverage matrix below).
- `stf_revert`: the full revert restore, the one shape whose position
  must be computed from the oracle at runtime (matrix below).
- `chaos`: the `simple` dispute with the node SIGKILLed and respawned
  on a seeded random cadence throughout.
  Reproduce or explore a seed with `CHAOS_SEED=<seed> just e2e echo
  chaos`. Qualified 2026-07-02 with five
  consecutive green runs (seeds 1-5, 6-8 kills each); runs in CI with
  a fixed seed.
- `kill_catchup_batched`: B2 at snapshot gap 3 - the SIGKILL lands mid
  advance batch, the uncommitted records drop whole, and the resumed
  run must re-execute the batch to the oracle's settlement. It is the one
  real-signal kill of the runner partway through an input.

Lifecycle, dispute, garbage-collection, restart, multi-sybil and
sealed-leaf timeout scenarios run in the node's in-crate harness
(`cartesi-rollups/node/src/harness/`, `just test-node-harness`), where the
test owns the chain's clock; large inputs and the node's witnesses at every
transition shape are checked against the contracts in Foundry
(`NodeWitnessesTest`, `NodeProofsTest`).

## Steering disputes: patch chains

A sybil patch `{ hash, meta_cycle = M }` garbles the leaf whose
post-state sits at meta-cycle M, i.e. the result of transition M - 1.
Two rules govern where it bites (`patched_commitment.lua`):

- A patch applies only at levels where M is stride-aligned, so a
  mid-span M never changes the coarse commitments.
- The dispute descends through the EARLIEST divergent leaf of each
  level, so only the smallest effective patch of each level's span
  shapes the descent.

Steering a dispute onto a transition therefore takes a chain: every
non-leaf level gets M rounded up to its stride (the leaf enclosing M) and
the leaf level gets M itself. Each rounded patch is also the last leaf of
the level below, so the sybil's levels stay mutually coherent.
`Env.steering_patches` builds the chain from the deployed level table, in
256-bit arithmetic (window 1 alone starts at 2^68, past a Lua integer),
and `Env.run_steered_epoch` asserts that the dispute's leaf match sealed
on exactly the steered transition: it reads each leaf match's divergence
cycle from `sealedMatch`, pinned at its `LeafMatchSealed` block.

That assertion exists because hand-written chains drifted twice without
a trace. Pre-rewrite `stf_all` carried unaligned patches that never
applied. Then the 2026-07 chains used 2^28 links against a level-1 stride
of 27, and epoch 4's `1 << 68` overflowed to 0. A 2026-09-28 run showed
epochs 2 and 4 sealing on transition 2^28 - 1 (a closing slot while input 0
still ran), epoch 3 on 2^48 + 2^28 - 1 (an idle closing slot), and
`stf_revert` on an idle closing slot 162 big cycles past the revert; only
epoch 1 sealed on its intended transition.

The seal alone does not show that the transition was proved: a timeout win
leaves the same seal and the same settlement behind, and the node claims a
timeout before retrying a rejected proof, so a broken on-chain transition
could end as a timeout win and pass (CF-02 in the
[2026-09-29 clock refill review](reviews/2026-09-29-prt-clock-refill/REVIEW.md)).
`Env.run_steered_epoch` therefore also requires the sealed match's
`MatchDeleted` reason to be `STEP`, correlated through the match ID hash
that `LeafMatchSealed` indexes.

Coverage matrix (`stf_all`, one dispute per epoch, each asserted to seal on
the listed transition and to end in a STEP proof):

- Epoch 1, transition 2^44 - 1: closing slot of an idle big cycle
  (final ustep + ureset), reached through idle churn leaves.
- Epoch 2, transition 2: plain active ustep of input 0, with an
  interior agree-leaf seal proof.
- Epoch 3, transition 2^48: idle churn ustep (the interpreter noticing
  the machine is yielded), plus the divergence-at-position-zero seal
  (agree state = the level's initial hash).
- Epoch 4, transition 2^68: the fused feed of input 1 (input delivery
  with revert root + first ustep) - the only dispute past window 0, so
  replays cross a fed input boundary.

The full revert restore is pinned by `stf_revert` (yield program,
which rejects every input): its position is program-timing-dependent,
so the oracle reports each input's big-cycle count
(`settlement.processing_bigs`, captured at the yield before the revert
reloads the snapshot) and the scenario steers onto the closing slot of
the big cycle where the reject yielded. It goes through
`run_steered_epoch`, so it carries the same seal and STEP checks. (A
maximum-size input's feed is now a node witness vector replayed in
Foundry.) Not yet pinned: capacity boundaries (last input slot, last
stride).

Per-PR CI (`.github/workflows/build.yml`): the contracts jobs run the forge suites
(PRT disputes, structured STF tests and fuzz, and consensus); the workspace job
runs Rust fmt, Clippy, Lua lint and client unit tests, the Rust build and unit
tests, and the explicit image-backed engine differentials; the e2e job runs
`just e2e-smoke` (echo `simple`, chaos at seed 1, the batched catch-up kill,
echo `stf_all` and yield `stf_revert`), then rebuilds the devnet with
`DEVNET_GEOMETRY=two-level` and runs echo `simple` against it
(`just test-rollups-two-level-smoke`). The node, the oracle, and the steering
helper read the level table from chain. Unsteered scenarios patch at
`1 << 44`, an idle leaf under either table. On the two-level devnet, honeypot
`stf_all`, yield `stf_revert` and the batched catch-up kill have also passed
(2026-09-30).

The smoke list lives in the `smoke` recipe of `test/e2e/rollups/justfile`, and
CI and local runs share it. It runs serially and past failures, keeps each node
log in `_smoke/`, prints a results table, exits with the failure count, and
warns about any scenario file the list omits.


## Known coverage gaps

Recorded here so the characterization effort has a target list;
unverified claims - check before relying on them:

- (closed 2026-07) Crash/restart recovery: chaos and the batched catch-up
  kill in e2e, and the harness's `restart_after_*` tests.
- (closed 2026-07) Revert transitions at leaf level: `stf_revert`.
- Epochs at capacity boundaries (max inputs, input at the last stride).
- Provider misbehavior: RPC errors, long-range log splits, throttling.
- Multiple honest nodes defending the same epoch concurrently.
- The devnet's censorship budget is 0, so kill and chaos runs keep no slack:
  a slow debug build can read as a lost dispute (a lead, unmeasured).
- (closed 2026-07-25, moved 2026-10-01) Sealed-leaf timeout boundaries from
  the node's side: the harness tests
  `the_longer_clock_wins_a_sealed_leaf_by_timeout` and
  `both_clocks_expire_on_a_sealed_leaf` observe the longer clock winning after
  the retired midpoint and before its own deadline, and double elimination at
  exact equality. The maintained contract phase table lives in
  [`dispute-game.md`](dispute-game.md).
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

## Lessons that outlive the deleted suites

Correctness weight belongs in the fastest layer that can carry it, and a
suite outside every loop rots (honeypot `big_input` stayed broken from the 3.0
sealing change until 2026-07-08 because nothing ran it), so every scenario is
either on the per-PR smoke or deleted. Keep the oracle doctrine (the node is
the subject, never the source), seeded reproducible chaos, log-marker kill
points, and fixtures regenerated only after review. An epoch's input boundary
is the InputBox count at the accept transaction's block, so assert on content,
never on which epoch an input lands in, unless the test controls input timing
against settlement.

## Known blind spots, by layer

- The Rust tournament reader's focused suite covers the recursively owned
  `Dispute`, log-ordered local transitions, dynamic child discovery and
  descriptor enrichment, strict event decoding, finalized Solid plus
  disposable Foam, and the narrow observer boundary; event parity with the
  contracts rests on the Solidity, Lua, reader and end-to-end suites.
- Hero policy, context assembly, fulfillment, dispatch, and GC are separate
  unit surfaces. Table-driven planner tests cover terminal, join, timeout,
  phase, and recursive-child decisions; action tests cover proof/opening
  preparation; the recording sender proves that each prepared variant invokes
  exactly one mutation. Cleanup and concurrent matches run against a chain in
  the node harness (`the_node_collects_an_abandoned_match`,
  `the_node_collects_an_abandoned_child_tournament`,
  `three_sybils_lose_and_the_node_recovers_its_bond_first`).
- The fail-closed observation rule stays: if timeout status and its phase
  projection disagree despite being pinned to the same head, reject the whole
  observation. Retain the raw RPC responses,
  address, arguments, calldata, and pinned head; never retry or normalize the
  two reads into apparent coherence.
- The e2e scenarios run the node at snapshot gap 2 by default (since
  2026-07-13; it ran gap 1 before). At gap 1 three node paths were
  dark in every scenario: the non-boundary GC's modulo never fired,
  advance batches degenerated to single inputs, and dispute
  positioning never replayed past a boundary. Gap 2 lights all three
  everywhere at the cost of at most one input of replay, and
  `kill_catchup_batched` runs gap 3. No e2e scenario runs gap 1 since
  `kill_catchup` was cut (0a9976a0).
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

The baseline (2026-10-02, Apple M5 Max, caffeinated): the five-scenario smoke
all green in about 14.5 min wall, serial; `stf_all` takes 7 of them, simple and
chaos about 2 each, `stf_revert` 2.5 and the batched kill under 1. The run to
repeat before any handoff: `just e2e-smoke`. The smoke keeps one scenario's
state at a time; other runs leave their own. Sweep once results are read
(`just rollups-tests::sweep`): each retained scenario instance can leave ~5 GB
of forensic state. A nearly-full disk quietly slows every machine store;
`just doctor-e2e` warns when the litter passes 10 GB.

Where the wall time goes, by class, largest first: (1) protocol-timeout
fast-forwarding throttled by the harness poll loop; (2) per-scenario setup
and inter-phase waits (anvil spawn, epoch-0 roll, oracle commitment builds,
settlement polling).
Node-side machine work and tick cadence are NOT drivers at current
constants. Parallel `TEST_INSTANCE` lanes already remove serial
fixed-port execution from the wall-time model.

Levers: the fast-forward crank (ff=128), TEST_INSTANCE parallel
isolation, and the loud scenario deadline are done and default. Still
open: the test-shape constants profile (smaller clock allowances and
shallower trees would shrink protocol-time fast-forwarding at the
source; contracts-side gap, the engine's Structure is ready) - its
urgency dropped once the pinned reader landed.

Current tiering: every maintained scenario is on the smoke list, so per-PR CI
gives each one complete integration path. Yield's unique value is the revert
shape in `stf_revert`. CI keeps chaos at seed 1; explore other seeds by hand.

Diagnosis disciplines the incidents taught (details in the frozen
record):

- When independent processes freeze and resume in lockstep, check
  `pmset -g log` before blaming software: an unattended macOS run dies of
  idle sleep, not bugs. Hold the machine awake (`caffeinate -is`).
- A stale devnet once surfaced as a misleading consensus assert in a new
  environment. The e2e preflight now verifies the recorded inputs, state,
  and deployments before Lua or the node starts; `just doctor-e2e` reports the
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
   spawn blockchain and node, drive epochs with `run_steered_epoch` when the
   dispute must reach a specific transition, and with `run_epoch` or
   hand-rolled sybils when it does not matter where it lands. Take strides and
   heights from `env.reader:read_tournament_levels()`, never literals, so the
   scenario runs on either table.
3. Add `<program> <name>` to the `smoke` recipe's list in
   `test/e2e/rollups/justfile`; per-PR CI runs that list, and the smoke
   warns about any scenario file missing from it.
