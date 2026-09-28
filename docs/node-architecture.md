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

Before opening or initializing the database, startup resolves the tournament
factory from Dave consensus, reads its whole level table
(`tournamentLevelCount()` and every `tournamentParameters(level)` row) and its
configured state transition. The node compiles in no tournament geometry: it
accepts any table that passes `engine::TournamentGeometry`'s validator (the
root spans the 92-bit machine coordinate, each level tiles one leaf of its
parent, the leaf level steps single transitions, and the root stride lies
between one big cycle and one input window), and it refuses to start unless
`CartesiStateTransition.CM_MARCHID()` equals the `CM_MARCHID` exported by the
linked Cartesi Machine library. These checks run before database
initialization, so an incompatible deployment cannot create or alter local
state. Initialization then pins the table and the consensus address in
`sling_config`; the runner samples each window at the pinned root stride, and
a later start against another table or consensus is refused. Table stability
is a trust assumption of the parameters provider, so before planning any
action the Hero checks the descriptor of every tournament on its own path
against the pinned row for its level, and the root commitment it would join
with against the settled computation hash. Cleanup of other branches takes no
local commitment and skips these checks.

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
(blockchain-reader), `advance.rs` (machine-runner), `dispute.rs` (player), and
`completion.rs` (epoch-manager) - `snapshots.rs` is the boundary store (every
machine store, load, and clean), and `queries.rs`
is the role-free read surface. Every public operation is one
transaction closure. One node process exclusively owns a state directory;
SQLite coordinates its worker threads, not multiple node processes.

Committed snapshots are immutable and load with explicit `SHARING_NONE`,
which gives them private file-backed mappings and OS copy-on-write behavior.
The advance path checks out one unique clone and opens only that clone with
`SHARING_ALL`. Within a batch it owns at most one closed, immutable transient
rollback checkpoint plus one mutable working clone. An accepted input rotates
the working clone into the checkpoint and checks out a fresh clone; a rejected
input discards the poisoned clone and checks out a fresh clone of the current
checkpoint.

While an epoch is open, a tail shorter than `--snapshot-gap-inputs` remains
unexecuted until a full batch is available. Once the epoch is sealed, the
runner executes and publishes its final shorter batch before rolling the
epoch. Only the batch's final canonical boundary becomes durable: the runner
closes it, verifies that its root matches the content-addressed key, syncs the
stored machine, renames it without replacement, and then registers the
boundary together with every window root in one database transaction. A crash
can therefore orphan a durable directory but cannot leave a row pointing at
an undurable machine; it may replay at most one full batch. Dispute-time
snapshot densification is the deliberate exception to the normal gap cadence.

The runner's newest registered boundary - its durable cursor - is strict state,
not a best-effort cache. If its path has vanished or cannot be inspected as a
directory, or if its loaded root cannot be verified against the database row,
the node panics instead of laundering the invariant violation through the
polling retry loop. Normal filesystem-first publication cannot create that
state; it indicates a node bug, external mutation, or an underlying storage
failure.
Dispute positioning remains different: an intermediate boundary only shortens
replay, so an unavailable one may fall back to an earlier verified boundary
within the epoch.

Schema initialization owns one create-only `storage/sql/schema.sql`; there are
no migrations or ordered schema versions. On an empty database, startup applies
that file once and atomically records the node package version, the Keccak
hash of the exact schema file, and the commitment semantics version. On later
launches it executes no DDL: all three stored values must match the running
binary, or startup refuses the state directory before applying schema changes.
The raw file fingerprint catches schema changes between builds that share a
package version; the semantics version catches commitment changes that alter
neither. It attests which schema created
this node-owned cache; manual database mutation remains unsupported rather than
continuously audited.

The epoch-completion cursor is bound to one claimant address. A different
configured signer requires a fresh state directory: epochs completed for one
claimant may still hold another claimant's bonds. Incompatible schema or node
versions also require rebuilding a fresh state directory from the chain and
template machine, as does a change of commitment semantics: a change to leaf
values or transition shapes bumps `COMMITMENT_SEMANTICS` in
`storage/sql/schema.rs`, because the frozen crate version would not.

Main schema (`storage/sql/schema.sql`):

- `node_metadata(node_version, schema_fingerprint, commitment_semantics)` -
  immutable cache identity
- `epochs(epoch_number, input_index_boundary, root_tournament, block_created_number)`
- `inputs(epoch_number, input_index_in_epoch, input)`
- `latest_processed(block)` - singleton; last finalized block ingested
- `epoch_completion` - singleton; fixed claimant and next unfinished epoch
- `settlement_info(epoch_number, computation_hash, final_state, data block and
  sibling blobs for iflags_Y, HTIF tohost, and the TX buffer)` - the TX data
  block is the outputs Merkle root
- `machine_state_snapshots(state_hash, file_path)` + `epoch_snapshot_info`
  (which (epoch, input) has which snapshot) + `template_machine` (pins the
  genesis snapshot)
- `tournament_events(root_tournament, block_number, log_index, raw_log)` +
  `tournament_events_watermark` - the dispute reader's persisted finalized
  prefix: prunable derived store (chain-refetchable, deleted with the
  completed epoch); rows are final once written and never outrun the
  per-dispute finalized watermark

Every table belongs to one of four mutation classes - append-only
log, write-once cell (equal rewrites absorbed, disagreements fatal),
monotonic watermark, prunable derived store - and the schema's
trigger layer enforces the taxonomy against any writer, including raw
connections (`sql/schema.sql`, tested by `sql/discipline.rs`).
Snapshot directories are removed only AFTER the transaction that
unreferenced their rows commits: a crash may orphan a directory,
never dangle a row.

The manager drops an epoch's Hero before recording completion. The runner
collects released snapshots, dispute rows, and scratch directories while
planning its next batch, including idle polls. It collects only epochs below
both the completion cursor and its newest machine epoch. Neither chain
progress nor manager catch-up can delete the runner's newest durable boundary;
startup scratch cleanup uses the same bound.

The runner captures all three settlement leaves from one final machine root,
checks their emulator proof metadata, Keccak openings, nonzero `iflags_Y`, and
manual `RX_ACCEPTED` HTIF reason, and verifies that root again when publishing
the next epoch's initial boundary. It intentionally does not interpret the
HTIF response-length field. The boundary row and complete settlement row then
commit in the same SQLite transaction. Reads revalidate every persisted proof
against its final state so corruption fails before transaction staging.

One schema note to know about:

- The dispute tables (`sling_config`, `sling_nodes`) live in the main
  database. The quartet cache is restartable state, and `Hero` opens its own
  connection to the same file (shared file, disjoint tables, private
  connections). The per-epoch directory holds only scratch: dispute-time
  machine snapshots stored by root hash and engine machine work directories.
  Hero construction materializes nothing: `DisputeSource::on_store` reads the
  input count, the window-root quartet rows prepaid by the machine runner, and
  the final boundary hash. Below window granularity, disputes replay the
  machine like any nested level; leaf runs are not persisted. Completed-epoch
  collection deletes released `sling_nodes` rows, window roots included.

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

The epoch manager follows the durable cursor for its next unfinished epoch. It advances
only after finalized ingestion proves settlement and one finalized view of the
root and its linked descendants shows no remaining bond payment owed to this
claimant. A recovered bond, a foreign claimant, or a no-winner tournament is
complete; running and unknown dispositions are not. Restart resumes that
cursor. The manager handles settled historical epochs using recovery reads
and calls alone, without constructing a Hero or waiting for local execution.

Root settlement implies every linked descendant has finished. Creating a child
pauses the parent match's clocks, and resolving that match requires the child
to finish; the same constraint applies recursively regardless of bond
ownership. The `TOURNAMENT_RUNNING` check therefore adds no separate wait after
finalized settlement.

For the current epoch, each tick combines the Hero's action or one cleanup,
an applicable settlement step, and every available bond recovery in one batch.
Recovery runs even while the root is contested and retries on the same
finalized head. Latest may suppress an already-mined payment, but only finalized
state can complete the epoch. Settlement planners stay bound to the cursor's
epoch even if another participant has already settled it.

The node deliberately finishes its refunds before participating in the next
epoch. Other participants can advance the chain meanwhile. Operation accepts
this modest participation delay within the dispute allowance; there is no
promise that recovery never delays another action.

The lane is stateless. For every submission it reads the account's mined nonce
at Latest, obtains a fresh EIP-1559 fee estimate, and signs the batch at
consecutive nonces from that base. It submits each raw transaction to the
configured endpoint in order; a rejected submission does not discard the tail.
It does not wait for a receipt. Already-known transactions, underpriced
replacements, and stale nonces are ordinary retry states; every later tick
rebuilds intent from fresh observation. The mempool or a separately configured
revert-protecting endpoint arbitrates races and duplicates. The signer must be
exclusive to one node instance and funded for the whole pending batch's fee
envelopes and call values. Nested tournaments require their own join bonds.

## Known debts

State and storage:

1. Snapshot garbage collection removes directories after the transaction that
   unreferenced them commits. That removal is not serialized with concurrent
   reads or content-addressed re-adoption. Current worker-role sequencing is
   relied upon: if a publisher reused the path after GC unreferenced it but
   before post-commit removal, it could register the path before GC deleted the
   directory. Serializing removal with re-adoption is a separate follow-up.
2. Snapshot publication reuses a pre-existing content-addressed destination
   without rehashing that destination. The staged candidate is root-verified,
   synced, and renamed without replacement, but correctness still relies on
   exclusive state-directory ownership and no external mutation of committed
   snapshots.

Error handling and observability:

3. Panics and asserts remain on hot paths. The settle-mismatch
   assertions in `src/epoch_manager/mod.rs` deliberately stop on a
   consensus-critical local/on-chain disagreement. The semantic Hero path now
   returns observer, context, and fulfillment errors for ordinary invalid
   observations, but invariant `expect`s remain and still need a dedicated
   panic-surface audit.
4. Logging is unstructured and inconsistent between crates.
5. Every tournament and settlement request carries the configurable
   `15_000_000` gas default. A pool may require balance for
   `gas_limit * max_fee_per_gas + value`, not expected gas use; join value is
   therefore additional to the fee envelope. A batch needs enough balance for
   its cumulative fee envelopes and values, including nested join bonds.
   Per-verb limits and a calibrated operating funding floor remain pre-mainnet
   work.
6. The lane does not observe receipts or mined revert reasons. Revert protection
   at the submission endpoint may reject stale or racing transactions before
   inclusion, but the node neither requires that service nor detects a
   deterministic self-authored revert. Because reverted state remains
   unchanged, the same intent may be rebuilt and paid for again each tick.
   The lane also does not remember a pending transaction's fees: a
   later, different intent at the same mined nonce may wait until the earlier
   transaction mines, drops, or becomes replaceable at the fresh market quote.
   Operation assumes that this happens within the dispute clock budget.
   Preflight or repeated-intent escalation remains pre-mainnet work.

Structure:

7. The reader uses async recursion for dynamic tournament discovery. The
   Hero's machine work (commitment builds, proofs) runs inside the epoch
   manager task. It hands its runtime worker off first, so the other tasks
   keep running, but the manager itself waits: a long leaf build delays that
   epoch's refund and cleanup planning, wave submission (the only path that
   resubmits or reprices pending transactions), and shutdown (debt 9). The
   action that follows rests on an observation as old as the build; that a
   stale action can only revert is a lead resting on the contracts' state
   checks, not a verified claim. A background builder the Hero polls would
   remove both; it remains open.
8. Commented-out code blocks kept as reference (the test-scaffolding
   `instance.rs` snapshot logic) and disabled/empty tests.
9. No graceful-shutdown story for in-flight work: a mid-epoch machine run
   or mid-dispute reaction is only interrupted at the next poll.

Design assumptions:

10. Finalized-only persistence. The tournament reader additionally acts on a
    disposable number-range tail and point views at one sampled hash. It does
    not prove the tail belongs to that hash's ancestry; stale work is safe
    because mutators revalidate it, and the next tick rebuilds the tail.
11. One node instance per state dir; SQLite WAL is the only cross-thread
    coordination. Shared state-directory operation is unsupported and has no
    process lock or recovery protocol.
12. Ingestion holds the application's unprocessed input payloads and epoch
    events in memory, including temporary conversion copies, before committing
    them with the ingestion watermark. RPC range partitioning does not bound
    that total. Operation assumes this backlog fits available RAM and accepts
    cold-start and retry costs. A same-state restart resumes from the last
    commit; a fresh state directory ingests the application's history again.
    Bounded ingestion is warranted only if measured history sizes require it.
