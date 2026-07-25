# The node refactor campaign (settled 2026-07-05)

Status: COMPLETED AND FROZEN - the title date marks when the plan
settled; workstream entries kept landing through 2026-07-20 and their
notes live inline. Kept in place as cited provenance (code comments
reference its workstreams by number). Living successor:
docs/node-architecture.md.

The whole-node simplification plan, designed in discussion after the
single-crate consolidation landed. sling-design.md remains the deep
design of the dispute core (quartets, ruler, cache); this document is
the campaign above it: storage, machines, the tournament reader, the
workers, measurement, and the order of attack. Written to be a
sufficient briefing for a future session with no other context beyond
AGENTS.md and the docs it links.

Status of the ground it builds on: the node is one crate at
`cartesi-rollups/node` (modules: storage, blockchain_reader,
machine_runner, epoch_manager, machine, sling, strategy, tournament);
storage is the only SQL surface; one migration; the per-epoch dispute
database is gone; all e2e suites green (echo, yield stf_all, chaos,
kill scenarios).

## Principles

These are the taste decisions; every workstream below instantiates
them.

- Rich storage, not anemic: operations are domain transactions that
  preserve state invariants internally. Callers cannot hold the
  database wrong.
- Mutation discipline: every write belongs to one of four classes -
  append-only log, write-once cell (equal rewrites absorbed,
  disagreements fatal), monotonic watermark, prunable derived store.
  No other row mutation exists. This is checkable and should be
  checked (tests + SQL triggers as defense-in-depth).
- Memoryless workers: a tick is a function of storage, not of local
  state accumulated across ticks. Restart is the normal path, not a
  recovery path. Exceptions are named and justified.
- Types first, one authority per convention: coordinates, event
  folds, and machine verbs each have exactly one implementation; the
  types make invalid states unrepresentable where cheap. Iterate on
  the types; let them guide the rewrite.
- Crucial vs optimization, flagged at design time: wasteful-but-pure
  first, with the optimization documented next to it; optimize only
  after measurement prices it.
- Established vocabulary: paper and repo terms over invented ones.
  The honest validator is the Hero (paper term; the pre-sweep Lua
  harness used it too).

## Reference: the sequencer storage module

`../sequencer/sequencer/src/storage/` (sibling repo) is the style
reference for storage v2. Patterns to transplant, with their home
there:

- One `Storage` struct; per-writer-role `impl` blocks in sibling
  files (open/ingress/l1_inputs/recovery/l1_submission/egress). No
  facet objects, no traits.
- `read(|tx|)` / `write(|tx|)` closure helpers (Deferred vs Immediate
  transactions, open.rs) - every domain operation is one atomic
  closure, no per-method transaction boilerplate.
- SQL triggers and partial unique indexes as an invariant layer the
  Rust writer cannot bypass (write-once lifecycle columns, at-most-one
  open tip, contiguity checks; 0001_schema.sql).
- Monotonic watermarks via
  `ON CONFLICT DO UPDATE SET x = MAX(x, excluded.x)`.
- Saturating i64<->uN conversions at the SQLite boundary
  (convert.rs): corrupted rows degrade, not crash.
- Filesystem-first, database-second for fs artifacts: store the file,
  then commit the row; a crash leaves an orphan file, never a
  dangling row. Lease-count + FK RESTRICT for GC of fs artifacts.
- synchronous=FULL there because commits gate external broadcasts
  (wallet nonce). Decision for us: NORMAL suffices - the node is
  replay-tolerant by design and externalizes nothing keyed on a
  commit; revisit if that ever changes.

## Workstream 1: instrumentation and baseline

Do this first. It is cheap, it guards every later change against
silent regression, and it converts three parked decisions (D.2, the
two-tier seed of sling-design OQ9, snapshot economics below) from
vibes to numbers.

The latency table (sling-design OQ4), properly specified:

- Operations measured: span replay per tournament level shape, on
  {idle, active, mixed} spans; snapshot store and load; seed fold as
  a function of run count; the get_logs transition probe; a full
  join+seal proof descent; the batched advance commit (workstream 7);
  the root-hash cost curve vs delta since the last hash (workstream
  8).
- Workloads: echo, yield, and one synthetic compute-heavy program
  (which the capacity-boundary scenarios also need - build it once).
- Statistics: worst case and p50. The clock budget cares about worst
  case.
- Validity: timing loops assert and report the machine state they
  claim to measure, and every row carries its density label
  (docs/dimensioning.md, measurement discipline).
- Budget column: allowance per move per level, derived from
  ArbitrationConstants (log2step, height, matchEffort); the table
  ends in a margin column, and a negative margin is a consensus
  parameter bug, not a node bug.
- Home: a `just measure` recipe regenerates a checked-in table in
  this directory, fixtures-style; regeneration is a reviewed act.

Memory: RSS per worker sampled at tick; SeedTree size counters (run
count, node count) - the OQ9 corner made resident fold size a named
risk. Disk: state-dir breakdown (snapshots by epoch, db + WAL sizes)
logged at every epoch roll and asserted loosely in capacity
scenarios. Page churn: chunk-level diff stats between consecutive
snapshots (falls out of the chunk-CAS prototype below; it doubles as
the measurement instrument for the COW premise).

First baseline findings (2026-07-05, echo workload, measurements.md):
the 1M-run seed fold takes ~225 ms, so OQ9's TIME corner is dead and
only its resident-memory side remains open; snapshot resume is ~4 ms
(mmap assumption vindicated) but a stored snapshot is ~533 MB, so
disk is the real snapshot cost and the COW question below is live;
idle churn measures exactly 34 usteps/cycle (the convention, pinned
numerically); the ruler's fixed-point shortcut is confirmed (a 2^44
idle window replays in ~0.5 s, not the ~7 min naive churn would
cost), leaving ACTIVE windows as the only unpriced replay - the
heavy program (workstream 2b) is now the highest-value missing
measurement.

Stress findings (2026-07-07, measurements-stress.md, the sha256-burn
workload), RELABELED after the dimensioning discussion (see
docs/dimensioning.md, which this discussion produced): the measured
rows are BENIGN-DENSITY FLOORS, not worst cases - a fully active
level-1 root replay ~5.2 s, level-2 ~1.5 s against the ~300 s
per-move budget. Dimensioning proper follows the rule: clocks price
the trusted app's AVERAGE density (~50 executed usteps per big
against the 2^20 span), and must cover the app's heaviest gap, which
the trusted-app assumption keeps near the mean. D.2 store-at-miss's
real justification is not latency but the prefix-repayment divisor:
without it a descent re-pays the positioning prefix per stratum miss
(~6-8x) against the app's heaviest input. What stands unrevised:
disk is the one pressured resource (2.1 GB of snapshots after one
two-input epoch at gap 1), so the COW analysis stays the live
optimization question. Owed to the harness: density labels and
machine-state asserts on every timing loop, and the root-hash-cost
vs delta-since-last-hash curve (see workstream 8). Single-sample
dev-hardware numbers throughout.

## Workstream 2: test surface increment

Before aggressive movement, widen the nets:

- Tournament event recordings: tap an e2e dispute run and persist the
  raw log/event stream (per tournament address, with block numbers)
  as JSON fixtures. These are the oracle for the workstream-5 fold:
  the fold must reproduce, from fixtures alone, the states the
  current reader derived live. Record echo/simple and one multi-level
  dispute at minimum.
- Capacity-boundary scenarios (already owed): last input slot of an
  epoch, full windows, the synthetic heavy program.
- Storage discipline tests: after workstream 3, tests that prove each
  trigger fires (insert a violating row through a raw connection,
  expect ABORT) and that the four-class mutation taxonomy holds (no
  UPDATE statements outside watermark-raise; grep-level test is
  acceptable).
- The e2e battery (echo, stf_all, chaos, kill-all) stays the outer
  net for every step, as during the consolidation.

## Workstream 3: storage v2 (the keystone)

Adopt the sequencer patterns onto the existing schema. This is a
reshape of `storage/`, not a schema rewrite; the schema is already
close to the discipline.

File layout: `storage/{open.rs, ingest.rs, advance.rs, dispute.rs,
queries.rs, error.rs, sql/}` - open owns connection lifecycle and the
read/write closure helpers; ingest is the blockchain_reader's writer
role (consensus data); advance is the machine_runner's (state hashes,
snapshots, roll, GC); dispute is the Hero's (closed-epoch views +
quartet cache). One struct, `&mut self`, one connection; a worker
thread holds its own Storage as today.

Table taxonomy (the target invariant - enforce and test):

| table                   | class            | writer role |
|-------------------------|------------------|-------------|
| epochs, inputs          | append-only log  | ingest      |
| settlement_info         | write-once cell per epoch | advance |
| epoch_snapshot_info     | append + prune (gap GC) | advance |
| machine_state_snapshots | content-addressed store, prune via FK RESTRICT + fs trigger | advance |
| latest_processed        | monotonic watermark | ingest   |
| template_machine        | write-once cell  | migration   |
| sling_config            | write-once cell  | migration   |
| sling_nodes             | append-only, write-once-verify (the tripwire) | dispute |
| tournament_events (new, workstream 5 phase 2) | append-only log + finalized watermark | dispute |

Concrete changes:

- read/write closure helpers; every public operation becomes one
  closure. Deferred for reads, Immediate for writes, busy timeouts as
  today.
- `record_advance` becomes atomic: state hashes + snapshot index + GC
  in one write closure, machine stored to the content-addressed fs
  path before the transaction (idempotent; a crash orphans a
  directory, never dangles a row). This removes the crash window that
  produced the cff83f7 verify-on-conflict fix; the verify demotes to
  a pure tripwire.
- Commit cadence = tick cadence (workstream 7): one commit per K
  inputs, not per input. Data granularity is unchanged - per-input
  hash runs still land as rows - only the transaction boundary
  batches. Epoch roll flushes a partial batch.
- Triggers (defense-in-depth; Rust checks stay):
  - write-once on sling_config and template_machine rows;
  - sling_nodes: BEFORE INSERT, existing row with same key and
    different hash -> RAISE(ABORT, 'node cache collision ...');
    the Rust-side message and semantics stay identical;
  - contiguity: inputs dense per epoch (backs
    InputId::validate_next);
  - latest_processed raise via MAX() upsert instead of read-check.
- Saturating conversions module at the SQLite boundary.
- Read-only connections for anything that only reads (the Lua seam
  already uses `sqlite3 -readonly`; a Rust read-only opener is there
  if a future reader wants fail-fast semantics).

Settled at implementation (2026-07-08), where it deviates from or
refines the spec above:

- The fs trigger is NOT kept. Deleting directories inside the
  transaction inverts the crash invariant (a rollback or mid-statement
  crash restores rows whose directories are gone). Instead the GC
  deletes rows with RETURNING and hands the orphaned paths to the
  caller, who removes them strictly after commit - the sequencer's
  gc_unreferenced_dumps shape. This also frees the schema from the
  per-connection fs_delete_dir UDF.
- The content-addressed store itself was not crash-atomic (a SIGKILL
  mid-store left a partial directory at the final path, which the
  exists() gate then adopted on resume). Stores now stage at
  `.part-0x<hash>` and rename atomically; the rename is the commit
  point.
- Batch API: the runner accumulates an AdvanceBatch (per-input fs
  stores stay - the revert restore needs the previous boundary on
  disk - but no rows land until commit_advances writes the whole
  batch in one transaction). Reverts restore from the batch's
  in-memory boundary path; the mid-batch DB read is gone. Skipping
  mid-batch fs stores is the flagged optimization, parked: it needs a
  revert-replay design (reconstruct the pre-input state from the last
  committed boundary) before the stores can go.
- Write-once cells take the taxonomy literally: settlement_info,
  template_machine, and epoch_snapshot_info absorb identical replays
  and abort on disagreement (template_machine's INSERT OR IGNORE used
  to absorb disagreeing rewrites silently; epoch_snapshot_info's DO
  NOTHING likewise).
- latest_processed is a MAX() upsert; the InconsistentLastProcessed
  error and its read-check died. Equal/lower submissions absorb -
  replay-tolerance beats the lost tripwire, and the reader still
  guards with current > prev.
- Contiguity triggers cover epochs too (dense from 0), mirroring the
  Rust check that already existed.
- The sling_nodes prune from the advance role (roll's gc_old_epochs)
  is blessed as a cross-role delete; its safety invariant is named in
  the schema: DaveConsensus settles epoch N before sealing N + 1, so
  pruned epochs' tournaments are finished.
- foreign_keys=ON is now set per connection. It was never set before;
  FK enforcement silently rode the bundled libsqlite3-sys compile
  flag, and any external writer saw FKs off.
- The single migration was edited in place (one migration, one DDL
  path). Pre-existing dev state dirs keep the old schema and fail
  loudly on first GC (their old trigger references the UDF new
  connections no longer register): wipe the state dir.
- Watch moved to src/sync.rs; storage/sql shrank to the migration,
  the discipline tests, and the test helper; consensus_data.rs and
  rollup_data.rs dissolved into the role files.

## Workstream 4: Position, and one authority for the conventions

The meta-cycle conventions currently exist twice: bit-shift/mask form
in machine/instance.rs (advance_rollups, get_logs_rollups) and
div/mod form in sling/ruler.rs, with no shared code. The idle-churn
incident was this exact class of bug; the duplication is a standing
hazard.

- `Position { input: u64, big: u64, ustep: u64 }` as the coordinate
  type (the paper's (c, b, a) triple), owned next to the ruler.
  Pack/unpack to U256 only at the chain boundary and quartet math.
  Explore an explicit reset slot representation (uarch spans have
  period 2^u + 1; whether ustep carries a Reset variant or the ruler
  keeps the closing slot implicit is a types-design decision to make
  by trying both against the spec tests).
- `InputBoundary(u64)` newtype for snapshot positions end-to-end
  (SnapshotSource, storage index, get_logs positioning). Invariant,
  asserted at store time: a stored machine is yielded at an input
  boundary. The `<< LOG2_UARCH_SPAN_TO_INPUT` conversions at module
  seams disappear.
- The ruler becomes the only implementation of window/feed/close/idle
  conventions. get_logs - the last prototype remnant - becomes a
  ruler-guided "advance to Position, step once with logs": the Stf
  verbs grow log-producing variants (log_ustep, log_ureset, log_feed,
  log_revert mirroring the plain verbs). instance.rs's parallel
  dialect (advance_rollups and its shift/mask decomposition) is then
  deleted. Note the sequencing win: the log-verbs are exactly where
  the emulator 0.21 collectors (increment F) plug in, so this
  workstream de-risks F.
- The three machines (input-processor, big-arch, uarch) are coherent,
  not symmetric: the fused feed transition, the closing ureset (+
  revert on rejected inputs), idle churn, and halt absorption are
  real asymmetries the Ruler names. The goal is one driver and one
  coordinate type, not a grand unified machine trait.

## Workstream 5: tournament state = fold(events)

Current reader: recursive RPC walk of the whole tournament tree every
tick, from the tournament's creation block, at Latest, no cache, no
reorg stance; on the order of hundreds of RPC calls per tick for a
deep dispute. The redesign, types first:

- `TournamentEvent` enum: CommitmentJoined, MatchCreated,
  InnerTournamentCreated, MatchAdvanced/Sealed as the contracts emit
  them, MatchWon/TournamentFinished. Events carry their tournament
  address and block number. Inner tournaments are discovered by the
  fold itself (an InnerTournamentCreated event names the address
  whose log stream must also be fetched).
- A pure fold: `apply(State, Event) -> State`, deriving the full
  tournament tree structure. Unit-tested against the workstream-2
  recordings: the fold must reproduce what the live reader saw.
- Derivation policy, settled: always fold from genesis (the root
  tournament's creation block) over all events, every tick. Ticks are
  seconds-to-minutes apart and a full dispute is hundreds of events;
  compute is nothing. What needs optimizing is state FETCHES, not the
  fold. Consequently no derived state is ever persisted or kept
  incrementally - the reader is memoryless, cold start and tick are
  the same code path, and there is nothing to invalidate.
- Volatile overlay: whatever genuinely cannot be derived from events
  is point-read fresh each tick. Lead to verify during types design:
  clocks (allowance, paused/ticking) may be fully derivable from
  events plus block timestamps - if so the overlay shrinks to nothing
  structural and only per-block timestamp fetches remain (also
  append-only, also cacheable). Check against the Clock library in
  prt/contracts before assuming.
- Phase 1 (crucial): the enum, the fold, the overlay - fetching
  wastefully (full refetch per tick) but through the fold. Phase 2
  (optimization, mechanical once the fold is golden): persist events
  with block <= finalized into storage (`tournament_events`
  append-only log + finalized watermark, per tournament address);
  each tick appends newly finalized events, then fetches only the
  finalized->latest tail live, never persisting it.
- Reorg stance, one sentence: persisted events are finalized-only;
  the tail is scratch, refetched every tick; acting on tail-derived
  state is safe because ArenaSender is revert-tolerant and every
  action is re-derivable. Reading at the tip is required - waiting
  for finality would add Ethereum finalization latency to every
  dispute interaction.

## Workstream 6: the Hero

LANDED 2026-07-09 (details in the priority order below).

The dispute-fighting module, rewritten on top of workstreams 4 and 5.
The logic is not the hard part (the quartet source already serves
every tree query; the Lua strategy and the current strategy module
are blueprints); the rewrite is mostly the react loop consuming the
new tournament types and the renames landing.

Renames (each lands with the commit that touches its module, not as
a big-bang; glossary updated in the same change):

| current                  | new                | when |
|--------------------------|--------------------|------|
| Player                   | (done) Hero        | workstream 6 |
| Player::react            | (done) Hero::tick - tick over defend: the worker verb the campaign already speaks (a tick is a function of storage), and the GC ticks too | 6 |
| strategy module          | (done) hero module | 6 |
| PRTConfig                | (done) NodeConfig  | any  |
| MachineInstance          | (done) retired to tests/common/ | 4 |
| EpochData                | (done) retired with it   | 4 |
| cartesi-rollups-prt-node (binary) | unchanged for now - harness contract; revisit only with a deliberate seam commit | parked |
| sling (module name)      | keep the codename until increment F retires the reference collector; then reconsider | parked |

## Workstream 7: memoryless open-epoch worker

A tick: load the latest boundary snapshot, process up to K inputs,
commit their hash runs + the new boundary in one write closure
(workstream 3), store the machine, drop it from memory. Next tick
reloads. K is the existing --snapshot-gap-inputs knob; the epoch roll
flushes a partial batch.

Consequences: restart IS the loop (kill scenarios stop being a
special path); the per-input crash window is structurally gone; a
crash re-executes at most K inputs (bounded, deterministic, priced by
workstream 1). Snapshot load per tick is assumed cheap (mmap); the
baseline confirms or refutes.

Named exception to memorylessness: the Hero keeps its warm state
(seed tree, machines) across ticks within a dispute - reconstruction
is priced in the OQ9 corner. If the two-tier lazy seed lands, revisit
even this.

## Workstream 8: the constants pipeline

Port prt/measure_constants' derivation into the measure binary as a
`--constants` mode (native, no docker), on the corrected model this
campaign's discussions settled (docs/dimensioning.md):

- The chain: log2step(1) = the tallest leaf-level dense build that
  fits the inner timeout at AVERAGE density (clocks price the trusted
  app's average, never the 2^20 worst case - that is the
  un-disputable machine the trust assumption excludes); log2step(0) =
  the densest level-0 sampling inside the root slowdown budget;
  heights follow arithmetically, and the level count falls out.
- Inputs: --root-slowdown (2.0 accepted), --inner-timeout (60 or 30
  minutes), --hardware-slack (the pragmatic stand-in for a reference
  machine, printed into every output so results carry their caveat).
- The curve it needs measured: root-hash cost as a function of delta
  (big cycles) since the last hash. The emulator's incremental hash
  tree should make small deltas cheap; this curve decides how far
  log2step(0) can drop within the slowdown budget, and with it
  whether the two-level shape closes.
- Discipline: timing loops assert and report the machine state they
  claim to measure; every row carries its density label. measure.lua
  was audited 2026-07-08 (findings recorded in docs/dimensioning.md,
  measurement discipline): halt guarded, YIELD unguarded (fatal for
  rollups images), fragile enum coincidence in uarch halt detection,
  and heights rounded optimistically upward by up to ~2x. The port
  fixes all three and samples steady-state, input-fed regions rather
  than boot.
- Deliverable: a memo table (current constants vs recommendations at
  the chosen inputs) plus the coordinated-bump checklist
  (ArbitrationConstants.sol, rollups_machine::LOG2_STRIDE, fixtures,
  computation-hash.md's level table). Constants changes are contract
  changes: time any bump against the open audit.
- Stated goal (Gabriel): a two-level dispute by the end of the sling
  rewrite. Also wanted: a small test-shape constants profile so e2e
  disputes run in seconds rather than minutes (sling's Structure is
  already parameterized; the gap is contracts-side).

## Snapshot economics (the COW question)

Premise (Gabriel): an input mutates few pages relative to machine
size, so per-input snapshots should approach diff size. The premise
is measurable - chunk-level diff stats between consecutive snapshots
(workstream 1) - and should be measured before building anything.

Options, assessed:

1. Emulator-level incremental store (the right long-term answer).
   The machine already maintains a Merkle tree over its pages - it
   knows exactly what is dirty. A store-diff-against-base API would
   give literal diff-sized snapshots, filesystem-agnostic and
   verifiable against the hash tree. Requires the emulator team; put
   it on the 0.21+ conversation alongside the collector APIs.
2. Chunk-level content-addressed store at our layer (achievable now,
   portable). Split stored snapshots into fixed-size chunks, store
   chunks by hash in a CAS, manifest per snapshot; GC by chunk
   refcount with FK RESTRICT (the sequencer lease pattern). Costs a
   sequential read+hash pass per store; wins dedup across consecutive
   snapshots AND across epochs (pristine pages shared forever). Also
   doubles as the page-churn measurement instrument.
3. Filesystem reflink cloning (cheap partial win today). Opportunistic
   reflink in the content-addressed copy path (reflink-copy crate:
   APFS clonefile on dev Macs, btrfs/XFS reflink on Linux, fallback
   copy elsewhere). Caveat that bounds it: the emulator's store
   writes whole files fresh, so FS-level COW cannot share pages
   between snapshots regardless of filesystem until stores become
   partial writes - which is option 1 again. Never require a specific
   filesystem of validators.
4. Offline dedup (duperemove on btrfs) as a zero-code ops trick on
   Linux deployments; not architecture.

Verdict: measure (1 week of instrumentation), then option 2 if disk
pressure is real and option 1's timeline is long; ask for option 1
regardless. betrfs (the Be-tree research filesystem, distinct from
btrfs) is not a deployment option.

## Priority order

1. This document + tournament event recordings + baseline
   instrumentation (workstreams 1-2) - LANDED 2026-07, minus the
   capacity-boundary scenarios and the workstream-8 harness rows.
2. Constants pipeline (workstream 8) - time-sensitive: the current
   constants encode a slower emulator and the pre-sling cost model,
   and any resulting contract change wants to meet the open audit.
3. Storage v2 (workstream 3) - the keystone; batched-tick cadence
   included. LANDED 2026-07-08 (see the settled block above), with
   workstream 2's storage discipline tests and the workstream 7
   commit cadence; behind the full battery (echo, kill B2-B5, chaos,
   honeypot-all, yield-all) plus a fault-injection atomicity test.
4. Position + one convention authority (workstream 4) - kills the
   duplicated dialect, de-risks F. LANDED 2026-07-08: Position and
   InputBoundary in sling/structure.rs; ProvingStf log-verbs on
   MachineStf; Ruler::prove_transition replaces get_logs (byte parity
   pinned by a differential on the real machine); the prototype
   dialect (MachineInstance, EpochData) retired to tests/common/ as
   the differential oracle it already served as.
5. Tournament fold, phase 1 (workstream 5) - against the recordings.
   LANDED 2026-07-08: TournamentEvent + the pure fold
   (tournament/fold.rs, structure only; the overlay reasons are in
   its module doc - descent ambiguity under equal siblings, movers
   unnamed by MatchAdvanced, chain-owned winner logic);
   fetch_from_root fetches raw logs per discovered tournament and
   assembles the Player's unchanged TournamentStateMap (retired by
   workstream 6's DisputeState); recording
   tests fold echo_simple and the newly recorded multilevel_stf
   (five steered disputes). Phase 2 (persist finalized events)
   landed 2026-07-11; see item 8.
6. Hero rewrite + renames (workstream 6). LANDED 2026-07-09: the
   react loop re-founded on the fold's types - the reader's product
   is DisputeState, the fold plus a point-read TournamentOverlay per
   reachable tournament (level geometry, base cycle, winner,
   elimination readiness, clocks, MatchLive positioning per live
   match). TournamentState/CommitmentState/MatchState/
   TournamentStateMap deleted with the assembly translation layer:
   structure questions ask the fold (a commitment's live match is
   latest_match filtered by is_live), volatile questions ask the
   overlay; reachability is overlay membership. All chain-anchor
   tripwires survive, as do the four harness log markers verbatim.
   Renames landed per the table above. Verified behind units + the
   fold recordings + e2e echo, gc_match, gc_tournament,
   kill_mid_match - whose first run caught a workstream 5 era race
   the rewrite had preserved (tick block sampled once, overlay read
   at Latest): fixed by pinning every point read at the tick's
   block, which also cut the scenario from >2 h to ~4 min (the
   stalls and the crash were the same bug; suite economics in
   test-harness.md).
7. Memoryless worker (workstream 7) - mostly falls out of 3.
   LANDED with workstream 3's AdvanceBatch (2026-07-08), confirmed
   at workstream 6 time: catch_up reloads from the newest boundary
   each pass, records up to --snapshot-gap-inputs inputs, commits
   one write closure, drops the machine; restart and tick are one
   code path, and the epoch roll flushes partial batches. Still open
   from this workstream's text: pricing the per-tick snapshot reload
   (workstream 1's latency table), and the named Hero warm-state
   exception stands.
8. Fold phase 2 (persisted finalized events) - after the fold is
   golden. LANDED 2026-07-11, the soak gate satisfied by evidence
   (three full batteries and two crash investigations in which the
   fold itself never misbehaved): tournament_events raw-log table +
   per-dispute finalized watermark in the dispute role, tail-is-
   scratch enforced by a schema trigger (events cannot outrun the
   watermark), GC prunes with the settled epoch; the reader replays
   the stored prefix, live-fetches only watermark+1..latest, and
   persists the newly finalized slice - cold start replays instead
   of refetching. The equivalence oracle rides the recordings:
   stored-prefix-plus-tail folds identically to all-at-once at EVERY
   block boundary of the recorded dispute. Verified behind units,
   the differential, and a full 21/21 battery with timings at the
   clean baseline (the kill family's respawns all cold-start
   through the stored prefix).

Parked, with their gates (2026-07-20: the OQ9 two-tier seed LANDED
with one-engine step 3; D.2 store-at-miss REJECTED - tombstone in
snapshots.md): snapshot chunk-CAS / reflink (gate: disk
baseline); increment F 0.21 collectors (gate: workstream 4, then the
coordinated bump - still deliberately last); PR slicing (Gabriel,
2026-07-08: deferred to merge time, not a gate on campaign work; the
ultrareview window for this branch has passed. Shape settled when it
happens: thematic squash-slices along the campaign's phase
boundaries, aggressive squashing within a slice, never one
mega-squash; sweep the commit-hash citations in docs and comments -
cff83f7 and friends - for stable references when squashing).

Every step ships behind the full e2e battery plus whatever fixtures
its workstream added; no step is allowed to be load-bearing for the
next until its tests exist.
