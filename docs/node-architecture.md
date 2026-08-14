# Rollups node architecture

The rollups node (`cartesi-rollups/node/`) is the single-crate implementation
produced by the node rewrite. This document records how it currently works and,
just as importantly, an honest inventory of its remaining debts. Completed
campaign history belongs in Git and dated review evidence, not in the active
plans directory.

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

Before opening or migrating the database, startup resolves the tournament
factory from Dave consensus and reads its level-zero parameters. The binary
refuses to start unless the deployed root stride equals the node's compiled
window-root sampling stride and the root row spans the compiled 92-bit machine
coordinate. This is a deployment-compatibility assertion over trusted factory
configuration, not runtime validation of every tournament row. Deeper geometry
continues to come from each tournament's immutable descriptor as the recursive
dispute is discovered.

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

The storage module follows the sequencer's shape: `open.rs` owns connections
(WAL, `foreign_keys=ON`, `synchronous=NORMAL`, busy timeout, a
read-only opener) and the `read`/`write` closure helpers (Deferred vs
Immediate); writer roles live in per-role files - `ingest.rs`
(blockchain-reader), `advance.rs` (machine-runner), `dispute.rs`
(player) - `snapshots.rs` is the boundary store (every machine
store, load, and clean), and `queries.rs`
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

- The dispute tables (`sling_config`, `sling_nodes`) live in the main
  database. The quartet cache is restartable state, and `Hero` opens its own
  connection to the same file (shared file, disjoint tables, private
  connections). The per-epoch directory holds only scratch: dispute-time
  machine snapshots stored by root hash and engine machine work directories.
  Hero construction materializes nothing: `DisputeSource::on_store` reads the
  input count, the window-root quartet rows prepaid by the machine runner, and
  the final boundary hash. Below window granularity, disputes replay the
  machine like any nested level; leaf runs are not persisted. `gc_old_epochs`
  deletes settled epochs' `sling_nodes` rows, window roots included.

## Chain ingestion stance

Epoch and input ingestion consumes logs only up to the chain's finalized block
(`BlockNumberOrTag::Finalized`). Finality is trusted and those rows are never
rolled back. Oversized `eth_getLogs` ranges are handled by binary range
partitioning, triggered by provider-specific error codes passed in as
configuration (`--long-block-range-error-codes`). A successful response is
trusted to contain every matching log in its requested range; the node does not
cross-check it against a second provider or an on-chain event count.

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
use the same binary range partitioning as other log ingestion.

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

The timeout classification and selected phase projection for one Hero match
must agree at their pinned head; a contradiction rejects that observation
rather than normalizing it. The empirical watch and diagnostic capture policy
live in [test-harness.md](test-harness.md#known-blind-spots-by-layer).

Joining is the one Hero decision that does not use Foam as its semantic source.
The latest projection first acts as the negative and capability guard: if it
already contains the local commitment or no longer permits a join, no join is
sent. When it proposes a join, the node rebuilds that context from Solid and
submits only if Solid independently proposes the same join. The commitment,
opening proof, bond read, and target therefore come from finalized inputs and
state; deadline-sensitive responses continue to use Foam.

## Mutation scheduling and transaction submission

The epoch manager directly owns the one non-cloneable transaction lane. Every
tick submits at most one mutation: a Hero action, otherwise one cleanup action;
one settlement step when the dispute is no longer contested; or one recovery
action when all higher-priority work is absent. Recovery is sampled at most
once for each newly observed finalized head. Within one tick, clock-bearing
work is selected before maintenance.

The lane is stateless. For every submission it reads the account's mined nonce
at Latest, obtains a fresh EIP-1559 fee estimate, signs one fully specified
request, and hands the raw transaction to the configured submission endpoint.
It does not wait for a receipt. Already-known transactions, underpriced
replacements, and stale nonces are ordinary retry states; every later tick
rebuilds intent from fresh observation. The mempool or a separately configured
revert-protecting endpoint arbitrates races and duplicates. The signer must be
exclusive to one node instance.

## Known debts

State and storage:

1. Snapshot garbage collection removes directories after the transaction that
   unreferenced them commits. A concurrent reader can still begin loading one
   in the interval before that post-commit removal.
2. Snapshots are keyed by root hash but pruned by epoch bookkeeping;
   `stage_machine_store`'s exists() gate (`storage/snapshots.rs`) no-ops
   on hash collision across epochs, which couples correctness to GC
   ordering. Stores stage and rename atomically, so the gate cannot adopt a
   torn directory.
3. Finalized input and epoch ingestion accumulates the entire unprocessed
   block range into in-memory vectors before one database transaction. Range
   partitioning limits what each RPC request asks for, but not total backlog
   memory or crash replay. A long cold-start backlog should eventually be
   committed in bounded block or log chunks.

Error handling and observability:

4. Panics and asserts remain on hot paths. The settle-mismatch
   assertions in `src/epoch_manager/mod.rs` deliberately stop on a
   consensus-critical local/on-chain disagreement. The semantic Hero path now
   returns observer, context, and fulfillment errors for ordinary invalid
   observations, but invariant `expect`s remain and still need a dedicated
   panic-surface audit.
5. Logging is unstructured and inconsistent between crates.
6. Every tournament and settlement request carries the configurable
   `15_000_000` gas default. A pool may require balance for
   `gas_limit * max_fee_per_gas + value`, not expected gas use; join value is
   therefore additional to the fee envelope. Limiting production to one
   request per tick removed cumulative wave funding, but a fee spike can still
   reject an otherwise affordable action. Per-verb limits and a calibrated
   operating funding floor remain pre-mainnet work.
7. The lane does not observe receipts or mined revert reasons. Revert protection
   at the submission endpoint may reject stale or racing transactions before
   inclusion, but the node neither requires that service nor detects a
   deterministic self-authored revert. Because reverted state remains
   unchanged, the same intent may be rebuilt and paid for again each tick.
   The lane also does not remember a pending transaction's fees or priority: a
   later, different intent at the same mined nonce may wait until the earlier
   transaction mines, drops, or becomes replaceable at the fresh market quote.
   Operation assumes that this happens within the dispute clock budget.
   Preflight or repeated-intent escalation remains pre-mainnet work.

Structure:

8. The reader uses async recursion for dynamic tournament discovery, and the
   Hero's dispute loop runs inside the epoch manager task. Local machine and
   proof preparation can therefore pin a runtime worker. Moving local dispute
   work to the blocking lane remains open.
9. `EpochManager.epoch_hero: (Option<Hero>, u64)` - anonymous
   tuple state machine; `Hero` construction takes a pile of positional
   arguments.
10. Commented-out code blocks kept as reference (the test-scaffolding
    `instance.rs` snapshot logic) and disabled/empty tests.
11. No graceful-shutdown story for in-flight work: a mid-epoch machine run
    or mid-dispute reaction is only interrupted at the next poll.

Design assumptions:

12. Finalized-only persistence. The tournament reader additionally acts on a
    disposable number-range tail and point views at one sampled hash. It does
    not prove the tail belongs to that hash's ancestry; stale work is safe
    because mutators revalidate it, and the next tick rebuilds the tail.
13. One node instance per state dir; SQLite WAL is the only cross-thread
    coordination.
