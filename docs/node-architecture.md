# Prototype node architecture

The rollups node (`cartesi-rollups/node/`) is an acknowledged prototype,
scheduled for an incremental rewrite (working name: sling node). This
document records how it currently works and, just as importantly, an
honest inventory of its known debts. The debts list is the seed worklist
for the rewrite; keep it current.

What to preserve in a rewrite: the core architecture works and was chosen
deliberately - a central SQLite database with independent worker threads
that communicate and synchronize only through it. The schema is what
needs rework, not the pattern (the per-epoch side databases retired at
sling increment E).

## Process layout

`cartesi-rollups-prt-node` (binary) runs three workers on one tokio
runtime (`lib.rs run()`), each owning its own SQLite connection:

- blockchain-reader (async task): chain logs -> db (inputs, epochs,
  last processed block)
- machine-runner (spawn_blocking, the blocking lane): db inputs ->
  machine execution -> db (leaves, snapshots, settlement info)
- epoch-manager (async task): db + chain -> settle txs and dispute
  reactions

Shutdown is a `ShutdownSignal` (`src/sync.rs`): async workers race it
in a biased select against their tick sleep; the blocking worker
sleeps through its condvar half. Worker errors do NOT travel through
the signal - they return through JoinHandles. run() races an
interrupt against every handle, turns the first exit into a shutdown
request, then awaits EVERY remaining handle (dropping one would
detach its task mid-drain). A worker returning before shutdown was
requested counts as failure even on Ok: silence is not success.
Panics surface as JoinErrors and are treated like errors. All three
workers retry failed ticks with a warning rather than dying -
transient provider or storage hiccups cost one polling interval;
invariant violations are asserts and stay fatal through the panic
path.

## Storage

Everything lives under `--state-dir`:

```
state_dir/
  db.sqlite3          main database (WAL mode, busy_timeout 10s)
  snapshots/0x<hash>/ machine snapshots, named by machine root hash
  <epoch_number>/     per-epoch dispute scratch dir
    0x<hash>/         dispute-time machine snapshots
    engine/           engine machine work dirs
```

The storage module follows the sequencer's shape (storage v2,
docs/plans/node-refactor.md workstream 3): `open.rs` owns connections
(WAL, `foreign_keys=ON`, `synchronous=NORMAL`, busy timeout, a
read-only opener) and the `read`/`write` closure helpers (Deferred vs
Immediate); writer roles live in per-role files - `ingest.rs`
(blockchain-reader), `advance.rs` (machine-runner), `dispute.rs`
(player) - `snapshots.rs` is the boundary store (every machine
store, load, and clean; docs/plans/snapshots.md), and `queries.rs`
is the role-free read surface. Every public operation is one
transaction closure. The advance path is batched and rides a chain
of clones: the runner mutates a working clone of the latest
boundary in place (SHARING_ALL), commits it into the
content-addressed store per accepted input (atomic rename; clones
are reflink-cheap where the filesystem cooperates), records up to
`--snapshot-gap-inputs` inputs per batch, and commits all their
rows in one transaction; a crash re-executes at most one batch, and
a revert discards the poisoned clone and re-clones the batch
boundary.

Main schema (`storage/sql/migrations.sql`):

- `epochs(epoch_number, input_index_boundary, root_tournament, block_created_number)`
- `inputs(epoch_number, input_index_in_epoch, input)`
- `latest_processed(block)` - singleton; last finalized block ingested
- `settlement_info(epoch_number, computation_hash, output_merkle, output_proof, final_state)`
- `machine_state_snapshots(state_hash, file_path)` + `epoch_snapshot_info`
  (which (epoch, input) has which snapshot) + `template_machine` (pins the
  genesis snapshot)

Every table belongs to one of four mutation classes - append-only
log, write-once cell (equal rewrites absorbed, disagreements fatal),
monotonic watermark, prunable derived store - and the schema's
trigger layer enforces the taxonomy against any writer, including raw
connections (`sql/migrations.sql`, tested by `sql/discipline.rs`).
Snapshot directories are removed only AFTER the transaction that
unreferenced their rows commits: a crash may orphan a directory,
never dangle a row.

One schema note to know about:

- The sling dispute tables (`sling_config`, `sling_nodes`) live in the
  main database since sling increment E; the quartet cache is the
  dispute's restartable state, and the dispute `Hero` opens its own
  connection to the same file (shared file, disjoint tables, private
  connections). The per-epoch directory holds only scratch: dispute-time
  machine snapshots stored by root hash, and the sling machines' work
  dirs. Hero construction materializes nothing: the facade
  (`DisputeSource::on_store`) reads the input count, the window-root
  quartet rows (prepaid by the machine runner as each window closes),
  and the final boundary hash; below window granularity disputes
  replay the machine like any nested level (no leaf runs are
  persisted - one-engine.md section 6, amended). `gc_old_epochs`
  deletes settled epochs' sling_nodes rows, window roots included.

## Chain ingestion stance

The reader consumes logs only up to the chain's finalized block
(`BlockNumberOrTag::Finalized`). That is the entire reorg strategy:
finality is trusted, nothing is ever rolled back. Oversized
`eth_getLogs` ranges are handled by recursive binary partition, triggered
by provider-specific error codes passed in as configuration
(`--long-block-range-error-codes`).

## Known debts (rewrite worklist)

State and storage:

1. (retired 2026-07-04, sling increment E; scratch GC closed
   2026-07-11) Per-epoch dispute databases are gone; the sling schema
   lives in the main database and the harness reads only
   `_state/db.sqlite3`, still exclusively through
   `prt/tests/rollups/dave/node.lua`. Settled epochs' scratch
   directories are swept at every roll and at startup
   (`sweep_settled_epoch_scratch`, the startup ritual's first step).
2. (half retired 2026-07-08, storage v2) The `fs_delete_dir` trigger is
   gone - GC returns orphaned paths and the runner removes them after
   commit. Still open: a post-commit removal can in principle delete a
   snapshot directory while another thread is loading it.
3. The `inputs_and_leafs.json` bootstrap side-channel in
   `DisputeStateAccess::new`, which also treats any db open error as
   "database does not exist" and swallows JSON parse errors.
4. Snapshots are keyed by root hash but pruned by epoch bookkeeping;
   `store_if_needed` no-ops on hash collision across epochs, which couples
   correctness to GC ordering. (The partial-store half of this debt is
   fixed: stores stage and rename atomically, so the exists() gate can
   no longer adopt a torn directory.)

Error handling and observability:

5. Panics and asserts as control flow on hot paths: the settle-mismatch
   assert in `src/epoch_manager/mod.rs` (crashes the node exactly when it
   must act) and dozens of `expect`s in the hero module.
   (`MachineInstance` retired to test scaffolding at workstream 4; its
   window-local cycle bookkeeping was fragile in the same spirit:
   `advance_rollups`
   used to poison it with `run(u64::MAX)`, crashing any commitment
   build past window 0 (found by the increment-C differential and
   fixed 2026-07-02; no e2e scenario had ever disputed past window 0,
   which is the patch-position coverage gap in characterization.md.)
6. Logging is unstructured and inconsistent between crates. (The
   `print!("\r...")` progress output inside library code went away
   with `machine/commitment.rs` at workstream 4.)
7. (resolved 2026-07-11) Provider error codes were threaded as
   `Vec<String>` through four layers of constructors; they now live
   in the chain facade (`src/chain.rs`), built once per worker in
   lib.rs.

Structure:

8. (narrowed 2026-07-11) The three per-worker runtimes collapsed to
   one, with the machine runner on the blocking lane. Remaining: the
   Hero's dispute loop still runs async inside the epoch manager's
   task and pins a runtime worker during machine work; moving it to
   the blocking lane and de-asyncing the dispute path (async_recursion
   and .await noise) is the sync-core phase of
   docs/plans/simplification.md.
9. `EpochManager.epoch_hero: (Option<Hero>, u64)` - anonymous
   tuple state machine; `Hero` construction takes a pile of positional
   arguments.
10. Commented-out code blocks kept as reference (the test-scaffolding
    `instance.rs` snapshot logic) and disabled/empty tests.
11. `get_events` binary partition recursion has no depth bound.
12. No graceful-shutdown story for in-flight work: a mid-epoch machine run
    or mid-dispute reaction is only interrupted at the next poll.

Documented design assumptions (fine, but should stay explicit):

13. Finalized-only ingestion; no reorg handling by construction.
14. One node instance per state dir; SQLite WAL is the only cross-thread
    coordination.
