# The boundary store (designed 2026-07-13, landed 2026-07-14)

Status: LANDED - all five steps of section 7 are in, each
battery-gated; per-step status lives inline there. The design
sections below are kept as written (they are the reasoning of
record); where implementation diverged, the step notes say how. The
resource model (resource-model.md) supplies the disk/RAM numbers
and the CoW mechanism; this document supplies the abstraction
analysis and the plan. Emulator claims below were verified against
the emulator source (v0.20 line, submodule 8bfca69) on 2026-07-13;
file and line citations live in the section that uses them.

## 1. The store/load map today, and the verdict

Every machine store and load in the node, by component:

| site | verb | mechanics | why |
|---|---|---|---|
| RollupsMachine::store_if_needed (storage/rollups_machine.rs) | store | full cm_store into CAS, stage+rename | advance path: after EVERY accepted input, plus epoch roll |
| MachineStf::feed (sling/machine_stf.rs) | store | full cm_store into work_dir checkpoint-N | dispute path: pre-feed revert checkpoint, one per fed input |
| MachineStf::store | store | full cm_store | measure.rs only |
| Storage::set_initial_machine (storage/open.rs) | load+store | template import into CAS | node bootstrap |
| Storage::begin_advances / latest_snapshot | load | RollupsMachine::new | machine-runner resume point, roll |
| Storage::record_reverted | load | reload batch boundary | discard poisoned post-reject state |
| Positioner::ruler_at -> MachineStf::load/resume | load | Machine::load, CM_SHARING_CONFIG | dispute positioning, per quartet miss and per proof |
| MachineStf::revert_if_needed | load | reload checkpoint-N | mid-replay reject |
| Hero::new | load | full Machine::load | to read one root hash |

Verdict: the read side has a real seam (SnapshotSource,
increment D.1a) but only for the dispute regime; the write side has
none. Specific leaks:

- Two disjoint snapshot regimes write the same artifact. The advance
  path stores the machine at an input boundary into the CAS; the
  dispute path stores the machine at an input boundary into per-ruler
  scratch (checkpoint-N). Same state, same purpose family (resume /
  revert), different naming, lifecycle, and GC. Neither knows about
  the other: a dispute replay that crosses boundary k re-stores what
  regime 1 may have stored and GC'd, and its checkpoint dies with the
  ruler instead of warming the next descent.
- The revert checkpoint IS a boundary snapshot. MachineStf::feed's
  checkpoint is the machine at the window boundary, pre-feed - the
  exact artifact the store keys. It is stored under a positional
  scratch name and deleted on the next feed.
- Hero::new loads a 500 MB machine to read a hash that is already the
  CAS directory name and the epoch_snapshot_info row key.
- Full-copy stores everywhere: 533 MB / ~350 ms per accepted input on
  the advance path, and the same per fed input during dispute
  positioning (the dominant cost of a cold gap-64 positioning:
  ~63 x (feed 221 ms + checkpoint store 346 ms + run) ~ 35-40 s of a
  300 s per-move clock budget).

## 2. Identity: the input boundary, and why not the meta-cycle

The window-opening transition is fused: checkpoint write + input
delivery + first ustep are ONE transition producing ONE leaf
(ruler.rs step_until, prove_transition; the on-chain transition
matches). Consequences, reasoned from the ruler:

- There is no meta-cycle whose state is "input added and nothing
  more". Post-feed-pre-ustep is a physical machine state (feed
  returns before stepping) but it has no coordinate: no leaf, no
  addressable position. A snapshot of it could never be named.
- The big-arch view cannot even reach it: coarse mode feeds and then
  runs big cycle 0 whole (the fused ustep is subsumed), and
  process_input on the advance path does the same. The only states
  both views can reach AND the ruler can address are big-cycle
  boundaries (ucycle == 0), and of those only window boundaries are
  reachable without counting big cycles: run until yield.
- Therefore the natural stored artifact is the machine at a window
  boundary: yielded (or halted), pristine uarch, awaiting input k.
  Its identity is the input index k - "before input k" - which is
  what InputBoundary already encodes and both regimes already
  produce (process_input runs to the next yield; feed checkpoints
  pre-feed).

So the key is (epoch, input index), a u64 pair, not a U256
meta-cycle. The meta-cycle enters exactly once, at the seam where
the ruler world begins (InputBoundary::position, the factory's one
conversion) - already the case since the InputBoundary refactor.
The identity saturates: for k past the last input the state is the
epoch's final fixed point, and nearest_at_or_before answers the
anchor row naturally.

What the input-index key deliberately does NOT cover: mid-window
big-cycle boundaries (k, b, 0). Those are addressable and storable
(resume only asserts a pristine uarch), and increment D.2 noted that
boundary snapshots can never help below window granularity - levels
1-2 live inside one window, so every stratum miss re-pays the
intra-window prefix. That remains true and remains deferred: the
durable store speaks input boundaries only, and a future sub-window
tier is dispute-local scratch with its own (window, big) naming,
never rows in the durable store. Section 6 notes how the clone loop
makes that tier nearly free when the latency table finally prices
it.

## 3. Consumers and the bounded-effort doctrine

The node races dispute clocks (~300 s per move; dimensioning.md).
Every load must therefore cost a bounded, reasonable effort. The
consumers and their worst-case effort per load:

| consumer | frequency | effort today | bound sought |
|---|---|---|---|
| machine-runner resume | per tick | mmap load, ~4.5 ms | fine |
| roll, revert reload | per epoch / per reject | mmap load | fine |
| dispute positioning (ruler_at) | per stratum miss, per proof | up to gap-1 window replays, each with a full checkpoint store, then one intra-window prefix | <= 1 window replay after first touch |
| nested descent (levels 1-2) | per stratum miss inside one window | same gap catch-up repeated, plus the same intra-window prefix repeated | gap catch-up paid once; prefix stays (D.2 deferred) |

The gap catch-up repetition is the real hole: at production gap 64,
EVERY cold stratum of every nested descent re-pays up to 63 window
replays. Gabriel's on-descent snapshotting closes it: when
positioning crosses input boundaries, write each crossed boundary
back into the store (increment D's deferred "store-at-miss", at
window granularity). First positioning pays the catch-up once;
every later positioning in that dispute resumes at most one window
away. And critically, the write-back is free even without CoW,
because MachineStf::feed ALREADY stores the machine at every crossed
boundary (the revert checkpoint) - the design merely renames that
store into the shared CAS instead of burying it in per-ruler scratch.

## 4. Emulator facts the design stands on

Verified in the emulator source (v0.20, submodule 8bfca69):

- A stored machine is a flat dir: config.json + per-range .bin
  (data), .dht (dense hash tree), .dpt (dirty page tree), plus
  hash_tree.sht (sparse top) and hash_tree.phtc (page hash cache,
  ~50 MB at default size). No stored root hash, no checksums; load
  performs no cryptographic validation.
- cm_load(dir, ..., CM_SHARING_ALL) maps every file MAP_SHARED:
  guest writes land in the file's page cache immediately; the
  machine mutates the directory in place. Sidecars are mapped shared
  too, so dirty-page tracking is persistent.
- Destroy needs no flush for cross-process validity (msync MS_ASYNC
  + munmap; page cache carries the rest). The dir remains a VALID
  machine after destroy even without updating hashes: staleness is
  recorded in the persisted .dpt, and the next root_hash() rehashes
  exactly the dirty set. Calling root_hash() before destroy (needed
  anyway for the CAS key) leaves .sht exact and .dpt clean, so the
  next resume's root_hash is a pure .sht read.
- cm_clone_stored(from, to): read-only-class files (PMAs, RO flash)
  hard-link; writable files reflink (ioctl FICLONE / clonefile);
  fallback sparse-aware copy on EOPNOTSUPP/EXDEV. It clones sidecars
  too. NOTE: the echo image's rootfs drive is read_only: false
  (mounted rw), so the dominant 356 MB file is reflink-class, not
  hard-link-class.
- flock discipline: a SHARING_ALL load holds LOCK_EX on writable
  files for the machine's lifetime; clone takes LOCK_SH. You CANNOT
  clone a dir that is currently loaded SHARING_ALL - destroy first.
  Private loads (CONFIG/NONE, which map MAP_PRIVATE but still reuse
  the precomputed hash sidecars) take LOCK_SH and coexist with
  clones.
- cm_store has NO reflink awareness (plain sparse-aware writes), and
  there is no incremental store, no flush-in-place, no dirty-only
  store. So cheap boundary materialization must come from the clone
  loop, not from store.
- Durability caveat: no fsync anywhere. Process crash is safe (page
  cache); power loss can tear both snapshot files and (under
  synchronous=NORMAL) the last DB commits. Same exposure class as
  today; the node's replay-tolerance doctrine covers it, and the
  assert-on-load tripwire below turns silent corruption into a loud
  hole.

## 5. The design

One component owns every machine store and load in the node.

### The boundary store (storage/snapshots.rs)

The existing two tables ARE the right schema and stay unchanged:
machine_state_snapshots (content-addressed dirs; dedup, benign
races, write-once discipline) under epoch_snapshot_info (the
(epoch, input index) -> hash map). The new component absorbs the
mechanics scattered today across rollups_machine.rs (stage+rename),
advance.rs (GC), and queries.rs (lookups):

- nearest_at_or_before(epoch, k) -> (InputBoundary, PathBuf).
  Best-effort floor, exactly the SnapshotSource contract; rows whose
  dirs are missing or fail the hash check are skipped (self-heal by
  answering earlier - any stored point only shortens replays).
- checkout(path) -> Scratch: cm_clone_stored into a uniquely named
  staging dir under snapshots/. Scratch is the only mutable machine
  state in the system; it is invisible to rows until committed.
- commit(scratch, epoch, k, hash) -> PathBuf: rename into the CAS.
  Row insertion stays with the caller's transaction, as today - the
  advance batch commits all its rows in ONE tx; fs artifacts land
  first and orphans are swept, preserving the crash discipline
  (stage+rename; a crash never dangles a row).
- discard(scratch): remove. Poisoned post-reject states, abandoned
  positioning work.
- The GC verbs move in unchanged (gap GC, settle GC, orphan sweep).

Commit is idempotent (Gabriel, 2026-07-13), and content addressing
is what makes it so: committing a boundary that already exists
discards the scratch against the existing identical directory, and
the row insert absorbs an identical replay. Precisely: write-once
cell semantics - no-op when present and identical, loud failure
when present and divergent (the tripwire). Callers therefore never
check before writing: the dispute write-back commits every crossed
boundary unconditionally (a no-op wherever regime 1 already stored
it), and a crash-resumed batch recommits its prefix harmlessly.

One component, many instances (Gabriel, 2026-07-13): every load,
store, and clean in the node goes through this one interface. It is
instantiated per worker like Storage handles today (one SQLite
connection per thread; WAL plus the emulator's flocks arbitrate),
so the machine-runner and the Hero hold separate instances of the
SAME code over the same state dir.

On the SnapshotSource trait: folded away (landed with step 3). The
"sling stays storage-free" framing was too strong - sling's
integration layer already holds Storage handles (DisputeSource, the
quartet cache); the genuinely dependency-free core is
ruler/stf/structure/toy, and THAT boundary is carried by
RulerFactory (the Hero's toy tests run through ToyFactory, one
level above any snapshot source). So MachineFactory takes the
boundary store directly, the same pattern as DisputeSource taking
Storage; ListSource and EpochStartSource retired (the floor-answer
test moved to the store's unit tests), and the one interface has no
adapter re-describing half of it. If a non-storage source is ever
needed again, the trait can return.

Assert-on-load tripwire (new): every load through the store checks
root_hash() == the row's state_hash. Nearly free when sidecars are
clean (a .sht read), and it converts undetectable torn snapshots
(power loss; the emulator validates nothing) into a skipped cache
entry plus a loud warning. The resume point (latest boundary) walks
back to an earlier boundary on failure instead of trusting blindly.

### The advance path: a chain of clones

Today: one in-memory machine across the batch, full cm_store after
every accepted input (revert insurance + boundary material), gap GC
at commit. Under the clone loop, per input:

    working = checkout(previous boundary dir)
    load working SHARING_ALL -> process_input -> root_hash
    destroy
    accepted: commit(working) as boundary k+1; next checkout clones it
    rejected: discard(working); boundary k+1 row = boundary k row

The flock rule shapes the loop: destroy-then-clone, never clone a
loaded dir. Measured on the echo image (measurements.md, clone loop
section, APFS): clone 2.6 ms, destroy ~2 ms, incremental root_hash
1-2 ms, and a kept boundary costs 1-3.5 MB of physical churn
against today's 533 MB store - the phtc's LRU writes stay bounded
by touched entries, not the file. One surprise: load with
SHARING_ALL costs ~130 ms warm where a private resume is 4.5 ms
(suspected PTE population for MAP_SHARED across ~130k pages;
emulator-internal, unexplored lead). The per-input total ~145 ms
still beats today's ~350 ms store on time and is ~300x better on
bytes. MAP_SHARED does not slow the hash-hot sampling loop
(51082/s private vs 51030/s shared). On ext4 the clone's copy
fallback writes what cm_store writes today - strictly no
regression, and the hard-linked read-only class is free
everywhere. Batch atomicity, the gap GC, and restart-equals-tick
are untouched: the working clone is staging, so a crash orphans
scratch and resumes from the last committed row, re-executing at
most one batch.

The template import (set_initial_machine) becomes clone + hash +
rename: node bootstrap stops copying 533 MB through machine memory.

### The dispute path: positioning writes back through the store

The factory holds the store directly (the trait folded away, step
3), so both verbs are the store's own:

- nearest_boundary_at_or_before: live against the store rather than
  a static list snapshot, so densification by one factory (the
  source's) is visible to the other (the prover's) and survives
  restarts.
- insert_boundary: the write-back verb, idempotent by the write-once
  cell.

MachineFactory's ruler_at splits into the two worlds it already
implicitly contains: the boundary world (resume floor, then window
by window: feed, run to yield, revert check - committing each
crossed boundary through record_boundary) and the ruler world
(intra-window advance to the target position). The checkpoint
mechanism dissolves: the pre-feed store that MachineStf::feed does
today IS the boundary commit, and revert_if_needed re-clones the
current window's boundary instead of reloading a private
checkpoint-N. Scratch checkpoint dirs, and their sweep, disappear.

Densified rows are ordinary epoch_snapshot_info rows for the sealed
epoch; they become collectible at settle like everything else.

GC schedule is policy, eligibility is not (Gabriel, 2026-07-13):
with CoW absorbing most of the retained bytes, sweeping settled
epochs immediately at roll stops being urgent - the sweep may lag
settle by epochs or run as a periodic janitor. What must NOT relax:
which rows are eligible (settled epochs only; the sealed epoch's
rows are dispute state), and that retention is bounded by SOMETHING
(an epoch count or a disk watermark), because on a non-CoW
filesystem every retained boundary is a real copy. This laziness
leans on CoW working well, so it waits for the churn numbers; until
then the at-roll sweep stays. Measurement caveat for those numbers:
du overcounts shared extents on both APFS and btrfs, so churn is
measured by free-space delta (df) or fs-specific tools (btrfs
filesystem du), not by du on the clone. The collision tripwire extends across regimes for free: a
dispute replay recomputing a boundary regime 1 stored must insert
the identical hash or fail loudly - a cross-regime nondeterminism
probe at every overlap.

Whether the dispute ruler itself should run its machine as a
SHARING_ALL clone (positioning writes persist as it goes) or keep
private mappings for the hash-hot collect loop is a measurement
question, not a design question: both compose with the store, and
the destroy-at-position trick (destroy the positioning clone at
span_start, reload it private for the collect) gets both if
MAP_SHARED hashing measures slower. Default until measured: keep
collect on private mappings, exactly today's behavior.

### What does not change

Ruler geometry and every meta-cycle convention; the quartet cache
and its fanout; the seed tree (since replaced by the two-tier rows,
one-engine step 3); the schema; the batch transaction
shape; GC semantics; stage+rename crash discipline (the clone is
scratch until renamed); the e2e oracle doctrine. Correctness never
depends on CoW: every clone degrades to a sparse copy and the gap
knob remains the disk-vs-replay dial.

## 6. Costs, before and after

Echo-image numbers (measurements.md; churn numbers owed - see plan):

| operation | today | clone loop (CoW fs) | clone loop (ext4) |
|---|---|---|---|
| advance path, per accepted input | 533 MB write, ~350 ms | churn only (~MBs), ~10 ms | ~ today (sparse copy) |
| kept boundary, resident | 400-533 MB | churn only | ~ today |
| dispute positioning, per crossed window | full store + feed + run | clone + feed + run | ~ today |
| positioning, repeat visits | re-pays whole catch-up | <= 1 window (write-back) | <= 1 window (write-back) |
| node bootstrap (template import) | load + full store | clone + hash | sparse copy |

The phtc churn question is ANSWERED (measurements.md, 2026-07-13):
per-boundary physical churn is 1-3.5 MB on the echo image, so the
50 MB page-hash cache's LRU bookkeeping dirties only the touched
entries' blocks. The one open lead is the ~130 ms SHARING_ALL load
(vs 4.5 ms private) - acceptable, unexplained.

Closed (Gabriel, 2026-07-20), tombstoned so neither idea is
re-derived:

- Per-descent sub-window scratch (D.2): REJECTED. It optimizes
  big-arch advance to a span start - the fast term. Dispute cost
  is dominated by novel-leaf collection (uarch stepping with hash
  collection at fine strides), which no snapshot tier can save.
  The strongest recorded form (node-refactor.md: a descent re-pays
  the positioning prefix per stratum miss, ~6-8x, against the
  heaviest input) still loses: each re-pay belongs to its own move
  with its own clock budget, one prefix replay measures ~5 s
  against the ~300 s per-move budget, and the trusted-app rule
  keeps the heaviest gap near the mean.
- Gap 1 as the production default: REJECTED; the gap stays 64.
  Positioning write-back already makes repeat visits cheap, and
  the first-visit catch-up is bounded big-arch advance well inside
  margins. Gap 64 costs strictly less disk than gap 1 (a kept
  boundary's clone is the union of its inputs' page churn, not the
  sum), and whatever fixed per-boundary overhead exists amortizes
  64x. The resource-model note that gap 1 "would be affordable"
  stays true and stays an observation, not a plan.

## 7. Implementation plan (each step battery-gated)

1. LANDED. Bindings: SharingMode parameter on load (default CONFIG,
   preserving behavior), clone_stored, remove_stored - the
   stored-directory operations dispatch through an empty cm_new
   object (the C API rejects the NULL its header promises to
   accept). The round-trip tests pin destroy-validity through the
   real interpreter (linux.bin boot prefix), both the root_hash-
   before-drop and the crash shape, plus clone isolation and the
   advisory-lock rule (confirmed on macOS/APFS).
2. LANDED. measure.rs clone-loop bench: numbers in section 6.
   measure.lua stays the emulator-level first-pass alongside it.
3. LANDED. The boundary store extracted behavior-identically:
   stage+rename, lookups, and snapshot GC in storage/snapshots.rs;
   the Hero reads epoch_initial_hash from the row; the live floor
   query replaced ListSource, and the SnapshotSource trait folded
   away (section 5). The mutation-taxonomy discipline test now names
   the store's two DELETEs.
4. LANDED. The advance path is a chain of clones: begin_advances
   checkouts a working clone of the latest boundary and loads it
   SHARING_ALL; record_accepted is hash (sidecars exact) -> close ->
   commit_clone (rename into the CAS; dedup discards against an
   existing identical dir) -> checkout -> reopen, preserving the
   machine-runner's loop shape (the swap rides RollupsMachine's
   close/reopen_shared, an Option-inner forced by the flock rule);
   record_reverted discards the poisoned clone and re-clones the
   batch boundary. roll_epoch keeps store_boundary (a row-only no-op
   under the chain, and the cold-path belt); the template import is
   clone + hash + rename. Staging (.work-*, .part-*) sweeps at
   startup, the batch's spare clone on drop. Echo e2e green.
5. LANDED. The checkpoint IS the boundary commit: feed already
   computes the pre-feed root hash for the shadow slot, so the
   write-back keys off it for free. MachineStf's checkpointer has
   two modes - per-ruler scratch (the storage-less harnesses) and
   the store itself (the node, always): feed commits the crossed
   boundary via commit_boundary_machine (stored only where the CAS
   misses, row insert = the cross-regime tripwire - a scratch-path
   registration in the old differential test tripped it exactly as
   designed) and reverts reload the committed directory. ruler_at
   wires the write-back and gained the read-side assert-on-load: a
   loaded boundary must reproduce its row's hash or be skipped for
   an earlier one (torn snapshots lengthen replays, never brick the
   Hero; a corrupt epoch start stays fatal). Staging names became
   unique per store, closing a latent same-hash race between the
   hero and the roll. Positioning now densifies: the first cold
   catch-up pays the gap once and every later ruler resumes at most
   one window away.

Ordering rationale: 1-2 are small and prove the scheme before any
node change; 3 is the abstraction payoff independent of CoW; 4-5
each swap mechanics under a seam the batteries already exercise.

## 8. Queued: owning the snapshot filesystem (Gabriel, 2026-07-13)

The idea, for a near-future session: stop treating the host fs as
given. Split the node executable into two commands, sequencer-style:

- setup: creates the sqlite database, performs the blockchain
  fetches, interns the initial machine - with the machine's EPOCH as
  an argument, so a node need not start from genesis (its own design
  discussion: watermarks and epoch numbering). Fails if a previous
  setup is detected (e.g. the sqlite file exists).
- run: runs the node; fails if there is no setup.

Then setup can also create, format, and mount a volume for the
snapshot store - a loopback file plus mkfs plus mount - so CoW
support comes from us, not from whatever the operator's root fs is.
The manual recipe is already in resource-model.md; this automates
it.

Assessment (2026-07-13): sane, in two tiers.

- Cheap tier, this campaign: a capability PROBE at setup/doctor -
  create two small files under snapshots/ and attempt FICLONE
  (clonefile on macOS); report clone support definitively, with the
  one-command fix when absent. Never fatal (cm_clone_stored
  degrades to copies); pure DX-doctrine (fix the footgun in
  tooling, not docs).
- Sharp tier, queued: setup --snapshots-volume <size> that does
  truncate + mkfs + mount. Linux-only (macOS is already APFS), and
  mounting needs root/CAP_SYS_ADMIN - refuse cleanly otherwise;
  containers usually cannot (overlayfs also does not serve FICLONE;
  bind-mount remains the container answer). Prefer XFS with
  reflink=1 over btrfs for the managed volume: sqlite WAL on btrfs
  wants nodatacow mitigation, XFS reflinks without CoW-everything.
  run then verifies the volume is mounted and clone-capable before
  touching state. Failure modes to design for: loop-device leaks,
  unmount on teardown, resize.

Amended (Gabriel, 2026-07-20): the setup/run split is DECOUPLED
from the owned volume and promoted - it has standalone value
(idempotent bootstrap: setup refuses if state exists, run refuses
without it; the non-genesis epoch start; a clean container story
with setup as an init step). Diagnostic shape: one module, three
consumers - setup runs it and reports (hard failures refuse, soft
ones like no-CoW warn), a doctor subcommand runs the same
diagnostic on demand, run's preflight asserts the hard subset
only. The probe must run on the state dir's ACTUAL filesystem
(clone capability is per-mount, not per-machine; just doctor can
only see the checkout's fs, so the node-level home is necessary,
not cosmetic). The managed volume itself is DEMOTED behind probe +
graceful degrade + a documented bind-mount recipe: mounting needs
root/CAP_SYS_ADMIN, containers cannot mount at all, and a bind
mount lands back on the operator's fs anyway - so the sharp tier
serves only bare-metal Linux on a non-CoW fs. Queue it on
demonstrated operator pain.

## 9. Decisions (Gabriel, 2026-07-13)

- Advance path as a chain of clones: approved.
- The snapshot gap stays 64. CoW may make denser gaps affordable
  later; that is a separate decision after churn numbers.
- One interface for all loads, stores, and cleans (checkout /
  commit / discard / gc), used by both regimes - same code, not
  necessarily the same instance (see section 5).
- Commit is idempotent - expected to simplify callers (section 5).
- Dispute write-back persists through that same component.
- GC schedule may lag settle once CoW is validated; eligibility and
  boundedness do not relax (section 5).
- Measurement: invest in BOTH harnesses - measure.lua stays the
  clear first-pass emulator read, measure.rs measures the
  sling-specific stack (clone loop atoms, churn, MAP_SHARED vs
  private collect). The parked measure.lua retirement question is
  answered: keep it.
