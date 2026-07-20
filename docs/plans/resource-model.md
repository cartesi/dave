# Sling node resource model (written 2026-07-11)

Gabriel's ask, the day the 806 GB tempdir leak fell: build a mental
model of the node's disk and RAM use good enough to unlock
optimizations. Same rules as the simplification survey: every claim
cites code or a measurement; unverified claims are marked leads.
Measurements are from the echo devnet image on one dev machine.

## Disk: what exists and who deletes it

Everything lives under `--state-dir` (node-architecture.md has the
layout). The lifecycle table, verified against storage/:

| artifact | writer | deleter | when |
|---|---|---|---|
| db.sqlite3 (+WAL) | all workers | rows: the GCs below | continuous; KB-to-MB scale |
| snapshots/0x&lt;hash&gt;/ (CAS) | machine-runner at every gap-th input boundary; epoch roll | `sweep_unreferenced_snapshots_in` after `gc_previous_advances_in` (non-boundary rows, every advance pass) and `gc_old_epochs_in` (settled epochs, at roll) | fs removal strictly post-commit |
| &lt;epoch&gt;/ scratch (dispute machines) | the Hero's two ruler factories | `sweep_scratch_dirs_at_or_below` at every roll and at startup | epochs at or below M - 2 |
| tournament_events rows | dispute reader (fold phase 2) | `gc_old_epochs_in` at roll | settled epochs |

Nothing else accumulates. The e2e harness's `_state-*` litter and the
test-scratch story live in test-harness.md; they are not node
behavior.

## Snapshot anatomy: the number that matters

One stored echo snapshot is ~400 MB across 30 files, and two files
are 87% of it (measured on a real `_state`):

- 356 MB: the rootfs flash drive image (PMA 0x0080000000000000)
- 134 MB: the RAM image (0x80000000, 128 MB)
- 50 MB: hash_tree.phtc
- everything else: KB scale

The CAS keys on the machine root hash, so it dedups only bit-identical
whole snapshots. Two boundaries one input apart differ by a handful of
touched pages, yet each costs a full ~400 MB copy: the store is
whole-file, not incremental. THIS is the disk problem. The 2.1 GB
after one two-input epoch at gap 1 (measurements, workstream 1) is
five nearly-identical copies of the same rootfs and RAM.

## Steady-state disk formula

With gap G (default 64, open.rs DEFAULT_SNAPSHOT_GAP_INPUTS; the
harness's gap 1 is a test choice for dispute positioning, not the
production shape) and N inputs per epoch, the store holds roughly:

    (N_open/G + N_sealed/G + 2) x snapshot_size

open epoch boundaries + the sealed (disputable) epoch's boundaries +
template and epoch-start. Settled epochs contribute nothing: rows die
at roll, dirs die with the rows, scratch dies with the sweep. At
G=64, snapshot_size ~400 MB, and say 1000 inputs/epoch, that is
~13 GB resident - dominated entirely by snapshot_size, not count.

Spacing is therefore already solved by the existing knob: raising G
trades disk for replay, and replay is cheap - resume from a boundary
is ~4 ms (mmap) plus at most G-1 inputs of re-execution; the WORST
measured fully-active level-1 replay is 5.2 s against a 300 s clock
budget (measurements, workstream 1; nested-novelty caveats in
dimensioning.md still apply to dispute pricing). Catching up IS fast;
the assumption holds on the measurements we have.

## The disk optimization: the CoW clone loop (Gabriel, 2026-07-13)

The emulator we already pin (v0.20.0) ships the whole mechanism -
verified in its machine-c-api.h:

- `cm_clone_stored(from, to)`: clones a stored machine; read-only
  files become HARD LINKS, writable files become REFLINKS on CoW
  filesystems, sparsity preserved (header lines 474-483).
- `cm_load(dir, ..., CM_SHARING_ALL)`: "machine state will be fully
  on-disk" - mutations land in the backing files, not RAM copies.
- `cm_store(dir, CM_SHARING_ALL)` and `cm_remove_stored` complete
  the lifecycle.

The proposed loop, per advance: clone latest -> load the clone with
SHARING_ALL -> advance the input(s) -> destroy -> rename clone to
latest. The clone is scratch until the rename, so the stage+rename
crash discipline is preserved: a crash mid-advance never touches
latest. Boundary snapshots (the gap-spaced trail) are just clones
that are KEPT - and since the 356 MB rootfs never diverges, a kept
boundary physically costs only its churned blocks. The disk formula
collapses from count x 400 MB to one base + accumulated churn, and
the gap knob becomes nearly free (even gap 1 would be affordable,
which would also shorten dispute positioning).

The full design that builds on this mechanism is
docs/plans/snapshots.md (the boundary store). What must be verified
before building on it (the prototype's assertions, in order):

1. Round-trip validity: clone -> load SHARING_ALL -> advance ->
   destroy -> reload -> root hash equals an in-memory advance of the
   same input. RESOLVED IN SOURCE (2026-07-13, emulator v0.20):
   destroy needs no flush - dirtiness is recorded in the persisted
   .dpt sidecars and the next root_hash rehashes exactly the dirty
   set, so the dir stays a valid machine; root_hash before destroy
   leaves sidecars exact. Two caveats found: a dir loaded
   SHARING_ALL holds flock LOCK_EX, so clone requires destroy first
   (the loop is destroy -> clone -> load); and load performs no
   cryptographic validation, so the node should assert the loaded
   root hash against its stored row. The round-trip test remains
   step 1, now pinning facts rather than answering questions.
2. Our Rust bindings expose none of this yet (Machine::load/store
   hardcode the default sharing) - a bindings extension, in-repo.
3. Filesystem coverage: APFS and btrfs/XFS reflink; ext4 degrades to
   real copies inside cm_clone_stored (correct, just not cheap) -
   the strategy must stay an optimization, not a correctness
   assumption.
4. Fragmentation: per-input 4 KB CoW writes fragment extents over
   time; a periodic full materialization (plain cm_store every N
   epochs) is the compaction valve. Price it when it shows.

Filesystem support, for deployment docs: there is no POSIX interface
for clones - each OS has one kernel API that abstracts over its
filesystems (Linux: ioctl FICLONE, served by btrfs, XFS with
reflink=1, bcachefs, OpenZFS 2.2+; macOS: clonefile(2), APFS). The
universal pattern is try-clone-then-copy (EOPNOTSUPP on refusal),
and cm_clone_stored already implements it, so the node programs
against the emulator, not the fs. APFS is CoW with first-class file
clones (every Mac since 2017), so dev machines get the full benefit
natively. A non-CoW production host has cheap outs: the state dir is
one self-contained mountpoint, so a btrfs/XFS partition, LV, or even
a loopback file (truncate + mkfs.xfs + mount -o loop) mounted there
suffices; RHEL-family XFS has shipped reflink on by default for
years (check: xfs_info | grep reflink). Container caveat: overlayfs
upper layers do not serve FICLONE - bind-mount a real CoW volume for
the state dir. Where nothing helps, cm_clone_stored degrades to real
copies (plus hard links for read-only files) and correctness never
depends on the optimization.

Fallbacks if verification fails: emulator-side incremental store
(the decision-6 ask), or chunk-level CAS in our store layer. Raising
the default gap stays the last resort; it is already 64 and count is
the smaller factor.

A bonus: the clone loop makes the page-churn measurement free -
after clone + advance, the clone's newly allocated blocks ARE the
churn. Measure by free-space delta (df) or fs-specific tools
(btrfs filesystem du); plain du overcounts shared extents on both
APFS and btrfs. Expected shape (Gabriel's intuition,
matching the ruler work): CPU/shadow state pages, the cmio rx buffer
pages (the input payload itself, up to ~512 pages for a 2 MB input),
a handful of kernel and app pages, plus the log-factor of hash-tree
sidecar updates above each touched page. Hundreds of KB to a few MB
per input against 400 MB per full copy. One suspect to watch: the
50 MB hash_tree.phtc is reflinked per clone and its LRU bookkeeping
writes on access, so it may dirty far more blocks than the input's
real page churn (snapshots.md, costs section).

Nuance found reading the test images (2026-07-13): hard links apply
to the emulator's read-only class (PMAs, read-only flash). The echo
image's rootfs drive is read_only: false (mounted rw), so its
356 MB file is reflink-class - free on CoW filesystems, a real
sparse copy on ext4. Images with a read-only rootfs get the
hard-link benefit on every filesystem.

## RAM: worker-by-worker bounds

- machine-runner: one machine (mmap; RSS = touched pages, not the
  533 MB store) + a batch of at most G inputs per commit
  (advance.rs). Bounded.
- epoch-manager / Hero: one facade holding at most one machine
  (one-engine steps 1-2 deleted the prover factory and every
  materialized payload vector; the feeder reads the inputs table at
  feed time). Level-0 serving is two lazy memoized tiers (one-engine
  step 3): the top tree over window-root rows is O(inputs) resident,
  and a window's interior folds only when a dispute descends into
  it - the max-tilt corner (~1M runs, ~hundreds of MB as a monolith)
  now costs one window's runs instead of the whole epoch's, and only
  on demand. Overlay maps bounded by live tournament structure.
  Bounded; PRECOMPUTE_LEVELS=8 subtree buffers (256 digests,
  trivial) remain the one flagged constant.
- dispute reader: the fold holds every event of one dispute
  (hundreds) plus the raw stored logs during replay. Bounded by
  dispute size.
- blockchain-reader: THE unbounded path. One tick fetches the whole
  `prev+1..finalized` range: chain.decoded_logs accumulates every log
  in one Vec (the bisection splits queries, not accumulation), every
  input body lands in a second Vec, and insert_consensus_data commits
  all of it in one transaction. Steady state that is one poll
  interval of blocks; on cold start or after downtime it is the
  ENTIRE backlog - every InputAdded since genesis in memory at once,
  and the watermark only advances after the single commit, so a crash
  mid-catch-up restarts from zero.

## The RAM optimization: bound the catch-up

DEFERRED (Gabriel, 2026-07-13): fine for now; devnet backlogs are
small and testnet deployments restart from recent genesis. The
design when it is picked up: cap each tick's range at K blocks (or N
logs), commit and advance latest_processed_block per chunk, and let
the loop iterate. Memory becomes O(chunk), crash recovery becomes
O(chunk), and steady-state behavior is unchanged (the range is
already small). The sequencer's input reader shares the hole - see
below - so the fix is a candidate to transfer upstream.

## The sequencer's answers (input reader), read 2026-07-11

A surprise, worth stating plainly: the sequencer's L1 input reader
does NOT bound its catch-up either. Its advance_once
(sequencer/src/l1/reader.rs:222-339) fetches the whole
`scan_floor+1..safe_head` range in one call, holds every decoded
input in Vecs sized to the full event count (reader.rs:283-284), and
lands everything in ONE transaction with ONE watermark advance
(storage/l1_inputs.rs:156-203). Its range bisection
(partition.rs:52-76) is reactive to RPC too-large errors and
concatenates the halves back into one Vec - it bounds per-request
size, never in-memory size. InputReaderConfig has no page-size or
max-range field. Both nodes share the same cold-start hole.

The strategies live in the sequencer's OTHER workers, and those are
the transferable shapes: the inclusion lane consumes persisted
inputs in bounded chunks (safe_input_buffer_capacity chunking,
ingress/inclusion_lane/mod.rs:315-321; DEFAULT_MAX_USER_OPS_PER_CHUNK
= 64) and the L2 tx feed paginates at DEFAULT_PAGE_SIZE = 256
(egress/l2_tx_feed/mod.rs:48). Applied to our reader: cap the range
per tick, commit per chunk, advance the watermark per chunk - the
pattern their inclusion lane already proves out one layer down. A
fix here is also a candidate to send back upstream to the sequencer.

## Related harness lead: gap 2 as the e2e default

The harness pins gap 1, where three code paths go dark in every
scenario: gc_previous_advances_in's non-boundary DELETE
(`input_number % 1 != 0` is never true - the prune never executes),
the multi-input advance batch (batches of one; only
kill_catchup_batched exercises batching), and replay-past-a-boundary
during dispute positioning (every input is a boundary). Gap 2 lights
all three in every scenario for at most one input of extra replay
(~seconds). Keep one scenario at gap 1 - the modulo degenerate case
is itself worth coverage. Needs a battery run to land.

## Measurement debts

- Page churn per input: free once the CoW clone prototype exists
  (the clone's allocated blocks are the answer); a manual
  stored-snapshot diff works before then.
- RSS sampling in the measure harness (owed since workstream 1):
  turns the RAM bounds above from code-derived to measured.
- A long-backlog catch-up benchmark (say 1M blocks of devnet
  history): prices the reader chunking when it is picked back up.
