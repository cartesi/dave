# Rollups node architecture

The rollups node (`cartesi-rollups/node/`) is the single-crate implementation
produced by the sling rewrite. This document records how it currently works and,
just as importantly, an honest inventory of its remaining debts. Dated plans
under `docs/plans/` preserve the rewrite history; they are not the current
architecture specification.

The core architecture is deliberate: a central SQLite database with independent
worker threads that communicate and synchronize through its transaction
boundary. The per-epoch side databases retired during the rewrite; remaining
schema and storage debts are tracked below.

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
- `settlement_info(epoch_number, computation_hash, outputs_merkle_root, outputs_merkle_root_proof, final_state)`
- `machine_state_snapshots(state_hash, file_path)` + `epoch_snapshot_info`
  (which (epoch, input) has which snapshot) + `template_machine` (pins the
  genesis snapshot)
- `tournament_events(root_tournament, block_number, log_index, raw_log)` +
  `tournament_events_watermark` - the dispute reader's persisted finalized
  prefix: prunable derived store (chain-refetchable, deleted with the
  settled epoch); rows are final once written and never outrun the
  per-dispute finalized watermark

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

Epoch and input ingestion consumes logs only up to the chain's finalized block
(`BlockNumberOrTag::Finalized`). Finality is trusted and those rows are never
rolled back. Oversized `eth_getLogs` ranges are handled by recursive binary
partition, triggered by provider-specific error codes passed in as
configuration (`--long-block-range-error-codes`).

The deadline-sensitive tournament reader holds one recursive, event-derived
`Dispute` through finalized `F`. On cold start it reconstructs that Solid value
from the persisted raw events. Each tick recursively extends every tournament's
local event stream through `F`, validates the completed tree, persists the
recognized logs and watermark atomically, and only then replaces the in-memory
Solid value.

After Solid advances, the reader samples latest `H`, deep-clones Solid, and
recursively extends the clone over the numeric range `F + 1..H`. This latest
quantum foam is used once and dropped. It is never promoted, reverse-applied,
compared with the previous tick, or checked for ancestry against `H`. A reorg
or mixed tail may reject the working tree, delay one action, or propose a stale
mutation. Contract mutators revalidate every transition, and the next tick
starts again from Solid. No unfinalized event becomes durable. Oversized ranges
use the same recursive binary partition as other log ingestion.

Events own tournament structure, commitment placement, match lifecycle, and
the inclusive block at which a clock-bearing match can be eliminated. Point
reads add only facts events do not carry: one immutable descriptor when a
tournament is discovered, one current standing per reachable tournament, and
the phase payload for each engaged match on the Hero's one recursive path.
When a parent resolution becomes Solid, its retained child subtree is frozen:
it remains available to recovery but no longer causes structural log fetches.
Standing calls use bounded concurrency. A clock-bearing Hero match needs a
timeout classification and one phase projection; a delegated parent needs only
its sealed projection. These reads are pinned to `H`. The observer narrows ABI
values into domain types; it does not reconcile a second whole-tree projection
against events. Transaction signing and submission remain strictly serial.

Joining is the one Hero decision that does not use Foam as its semantic source.
The latest projection first acts as the negative and capability guard: if it
already contains the local commitment or no longer permits a join, no join is
sent. When it proposes a join, the node rebuilds that context from Solid and
submits only if Solid independently proposes the same join. The commitment,
opening proof, bond read, and target therefore come from finalized inputs and
state; deadline-sensitive responses continue to use Foam.

## Known debts

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
3. (retired 2026-07-20, one-engine rewrite) The `inputs_and_leafs.json`
   bootstrap side-channel and `DisputeStateAccess` are gone; Hero
   construction reads everything from the main database through
   `DisputeSource::on_store`.
4. Snapshots are keyed by root hash but pruned by epoch bookkeeping;
   `stage_machine_store`'s exists() gate (`storage/snapshots.rs`) no-ops
   on hash collision across epochs, which couples correctness to GC
   ordering. (The partial-store half of this debt is fixed: stores stage
   and rename atomically, so the exists() gate can no longer adopt a
   torn directory.)

Error handling and observability:

5. Panics and asserts as control flow on hot paths: the settle-mismatch
   assertions in `src/epoch_manager/mod.rs` deliberately stop on a
   consensus-critical local/on-chain disagreement. The semantic Hero path now
   returns observer, context, and fulfillment errors for ordinary invalid
   observations, but invariant `expect`s remain and still need a dedicated
   panic-surface audit.
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

8. (narrowed 2026-07-11; async_recursion itself removed 2026-07-24 with
   the semantic interface) The three per-worker runtimes collapsed to
   one, with the machine runner on the blocking lane. Remaining: the
   Hero's dispute loop still runs async inside the epoch manager's
   task and pins a runtime worker during machine work; moving it to
   the blocking lane and de-asyncing the dispute path is the sync-core
   phase of docs/plans/simplification.md.
9. `EpochManager.epoch_hero: (Option<Hero>, u64)` - anonymous
   tuple state machine; `Hero` construction takes a pile of positional
   arguments.
10. Commented-out code blocks kept as reference (the test-scaffolding
    `instance.rs` snapshot logic) and disabled/empty tests.
11. (retired 2026-07-20, one-engine rewrite) `get_events`'s recursive
    binary partition became `logs_bisecting`'s iterative worklist
    (`src/chain.rs`); there is no recursion depth left to bound.
12. No graceful-shutdown story for in-flight work: a mid-epoch machine run
    or mid-dispute reaction is only interrupted at the next poll.
13. (resolved 2026-07-24; reshaped 2026-08-08) Hero actions, cleanup,
    settlement, and bond recovery share one explicit stateless transaction
    lane rather than a signer-bearing provider. The epoch manager owns the
    non-cloneable lane directly, making it the one mutation submitter. Hero
    and cleanup never share a nonce tail: a Hero tick emits at most one action,
    using cleanup only when no Hero action was selected. One guarded settlement
    step may precede an otherwise empty terminal tick. Bond recovery is
    not a wave tail: it runs only when higher-priority work is absent, at
    most once for a newly observed finalized head. Its tree and retirement
    classification share that finalized snapshot; a latest read may suppress
    an already-mined recovery but can never retire an epoch. Every send is
    rebuilt from fresh observation and fees, while the mempool or block
    builder arbitrates duplicates and replacements
    (docs/plans/self-healing-batch-submission.md). Read and submit endpoints
    remain independently configurable; the submit endpoint defaults to the
    read endpoint. The signer must still be exclusive to one node instance.

Documented design assumptions (fine, but should stay explicit):

14. Finalized-only persistence. The tournament reader additionally acts on a
    disposable number-range tail and point views at one sampled hash. It does
    not prove the tail belongs to that hash's ancestry; stale work is safe
    because mutators revalidate it, and the next tick rebuilds the tail.
15. One node instance per state dir; SQLite WAL is the only cross-thread
    coordination.
