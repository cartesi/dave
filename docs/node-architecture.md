# Rollups node architecture

The rollups node (`cartesi-rollups/node/`) is the single-crate implementation
produced by the node rewrite. This document records how it currently works and,
just as importantly, an honest inventory of its remaining debts. Completed
campaign history belongs in Git and dated review evidence, not in the active
plans directory.

The core architecture is deliberate: a central SQLite database with independent
worker threads that communicate and synchronize through its transaction
boundary. The per-epoch side databases retired during the rewrite.

## Process layout

`cartesi-rollups-prt-node` (binary) runs three workers on one tokio
runtime (`lib.rs run()`), each owning its own SQLite connection:

- blockchain-reader (async task): chain logs -> db (inputs, epochs,
  last processed block)
- machine-runner (spawn_blocking, the blocking lane): db inputs ->
  machine execution -> db (window roots, snapshots, settlement info)
- epoch-manager (async task): db + chain -> settle txs and dispute
  reactions

Before opening or initializing the database, startup resolves the tournament
factory from Dave consensus, reads its whole level table
(`tournamentLevelCount()` and every `tournamentParameters(level)` row) and its
configured state transition. The node compiles in no tournament geometry: it
accepts any table that passes `engine::TournamentGeometry`'s validator (the
root spans the 92-bit machine coordinate, each level tiles one leaf of its
parent, the leaf level steps single transitions, and the root stride lies
between one big cycle and one input window). It does not judge whether a
table can be built in time (one warning for a leaf taller than its measured
capacity) and does not pin or check `T`. It refuses to start unless
`CartesiStateTransition.CM_MARCHID()` equals the `CM_MARCHID` exported by the
linked Cartesi Machine library. It then inspects the `--machine-path` template
(one private load: its root hash, the pristine-uarch check, and whether it is
paused at a manual accepted yield) and requires that hash to equal the
consensus's initial hash. A matching template paused elsewhere is the deployed
application's own and still refused: the engine starts every epoch from a
state awaiting input, so the node could not defend any of its epochs. Only
then does it take the state-directory lock and open the directory. A seeded
directory is compared with its `sling_config` pins (app, chain, consensus,
template, emulator and table) before anything is written, and the claimant is
pinned before any worker starts. A mismatch names the flag to fix
(`--app-address`, `--web3-chain-id`, the signer's), calls the directory another
deployment's or an old one (the template), or asks for a rebuild (consensus,
emulator, table). A new directory is seeded in one transaction: the genesis
watermark, the epoch-0 boundary, the template row and the pins. So a deployment
or flag these checks reject cannot create or alter local state, and a restart
never imports the template again. The runner samples each window at the pinned
root stride. Other operator mistakes (an unknown chain id, an unreadable or
invalid key, an endpoint on another chain, an address that is not a Dave
application) are errors that name their flag too; they add no URL or key
material, though a transport error's own text may carry the endpoint. The
initial hash comes from epoch 0's `EpochSealed` in the consensus's deployment
block, which the consensus records as `block.number`: where that is not the log
block coordinate (Arbitrum reports the parent chain's), the node cannot locate
genesis and does not start. Table stability is a trust assumption of the
parameters provider, so before planning any action the Hero checks the
descriptor of every tournament on its own path against the pinned row for its
level, and the root tournament's initial hash against the node's epoch-start
snapshot. Both are invariant violations and panic. Cleanup of other branches
takes no local commitment and skips these checks.

Shutdown is a `ShutdownSignal` (`src/sync.rs`): async workers race it
in a biased select against their tick sleep; the blocking worker
sleeps through its condvar half. Worker errors do NOT travel through
the signal - they return through JoinHandles. run() races a stop
signal (SIGINT or SIGTERM) against every handle, turns the first exit
into a shutdown request, then awaits EVERY remaining handle (dropping
one would detach its task mid-drain). A stop signal during that drain
exits at once, which is as crash-safe as SIGKILL. A worker returning
before shutdown was requested counts as failure even on Ok: silence is
not success.
Panics surface as JoinErrors and are treated like errors. How a worker
fails is the failure policy below.

A stop request stops each worker at its next safe point. The reader drops
its tick in flight, whose one write, the chunk's commit, follows every await.
The runner stops before its next input and drops an unfinished batch, which a
restart replays as after a crash. The manager finishes its tick, so an action
whose preparation completed still goes out with the tick's recoveries, but
the Hero's machine work stops early: positioning before its next crossed
input, and a stride-0 build at least `c + 8 = 28` high (the leaf level of a
two-level table) before its next bottom-stratum span. Finished spans stay in
the quartet cache, and the restarted node's build resumes after them.
Everything else runs to completion: one input's replay, a recompute below
that height, the leaf and middle builds of the three-level table (seconds to
minutes, unmeasured), and the tick's RPC calls (the recovery scan,
estimation, submission). So a stop can drop a due action's preparation,
which the restarted node prepares again after its Hero refolds the live
tournaments' logs.

## Failure policy

The Rust node is the only honest dispute client; the Lua player is an e2e
adversary. Every honest node runs this code on the same chain, so whatever
chain data deterministically stops one node stops all of them at the same
block, and the adversary picks the block. That makes two rules protocol
safety, not hygiene:

- P1. If an adversary can make the honest node halt or stall
  deterministically, N honest nodes protect like zero. No check may reject
  a state or event sequence the contracts can produce, or an input the
  trusted application can process. This generalizes the tournament fold's
  rule (Chain ingestion stance, below): the fold rejects only an event it
  cannot apply without guessing, a sequence the contracts cannot emit, so its
  rejections fire only on RPC faults, reorged tails and node bugs. On a path
  the clocks depend on there is no safe way to fail, since holding a dispute
  step is the stall. Holding is safe only off the clock path: a won root whose
  final state cannot settle is held with an error log (epoch-lifecycle.md,
  the terminal application).
- P2. Spend distrust where a lie would be silent, not where it would fail
  loudly. Ingestion checks every input's index, and its totals against the
  chain's at the finalized head, because a dropped log would silently shift
  every later commitment. Re-proving contract rules on the
  dispute path buys little against commission: a fabricated value yields an
  action the contract rejects, which the lane skips at estimation with a
  warning, and an error when the same call repeats on the next tick. It does
  nothing against omission or a lying read: a missing finalized log or a
  false standing can make the Hero wait instead of act, and nothing reverts.
  The fold keeps the guards that stop it from guessing; tournament-log
  completeness and truthful pinned reads otherwise stay trusted RPC
  properties.
- When the two conflict, split the check: keep a panic only for what
  corruption alone can reach, and move what chain data can reach off the
  clock path. f371381c did this after a terminal application panicked every
  node at the roll, which would have let a fabricated claim win uncontested.

Apart from the two accepted halts and the trust model below, chain data
reaches no panic on the dispute path until a wrong epoch has settled: the Hero
then panics on a root that starts from a state it did not compute, an
already-defeated protocol. Chain-reported coordinates reach the engine only
through validators that accept everything the contracts produce. The observer
checks each match against its tournament's descriptor (height, position,
alignment, cycle) and the Hero's snapshot checks it again; a bisecting match
must stand above height 1, since advancing opens the children of the node
below the contested one; a level's base cycle must be aligned to its span, and
a child's must be its parent's divergence cycle; and every level's stride and
height must match the pinned table, which tiles the machine coordinate.
Nothing checks that the root's base cycle is 0; the trusted factory sets it.
The observer's standing decoders likewise front its own `expect`s on
candidate and parent-match data. The engine's asserts behind them
(`LevelCoords`, `Quartet`, the ruler) are tripwires for node bugs, so a prune
must keep these validators or first turn the asserts they front into errors.
The settle asserts compare the local result with one block's views after the
node's own win (epoch-lifecycle.md, settlement invariant), so they too fire
only on a node bug or corrupt local state.

Two input-reachable halts are accepted rather than defended. More than 2^24
inputs in one epoch: the contracts handle it (they never feed the tail) but
the node panics, and reaching it takes a flood of about 5e11 gas
(dimensioning.md); a defect accepted on cost. An input whose computation
overruns its window: the engine panics rather than invent a transition shape
(`engine/ruler.rs`); the trusted application and the per-input compute
contract keep it out of model. P1 also holds only inside the trust model, and
a broken trusted assumption may stop every node at once: finalized and
complete RPC data; a stable parameters provider (the Hero panics on a level
that left the pinned table); and a template and guest that yield through
well-formed requests (a template preset with a malformed request panics the
runner, while a guest's oversized yield throws and the runner retries it
forever). One failed standing read or finalized fold fails the Hero's whole
tick, and a failed refund scan holds the epoch's completion; an audit of the
node's panics and retry loops found no data the contracts can produce that
fails any of them deterministically.

Workers retry a failed tick with a warning that carries the whole error chain:
a transient provider or storage error costs one polling interval, and a
warning that repeats tick after tick is a stall to investigate. A retry loop
that should page reuses the epoch manager's consecutive-tick rule
(`repeated_reverts`: a warning first, an error on the next tick). One stall
needs an operator: a log missing from the tail of a catch-up chunk (rebuild
the state directory). A tournament event that does not fold onto the reader's
finalized prefix, or a phase read on the Hero's path that contradicts it, drops
the prefix, and the next tick refolds from the root's creation block as a
restart would; any other omitted log that still folds is not detected (RPC
completeness is trusted). Asserts are for states reachable only through a node
bug, corrupt local state, a broken trusted assumption, or an already-defeated
protocol; there, stopping loudly is the alarm. A panic stops every worker,
refunds included (`lib.rs`, `worker_failure`), and a restart re-plans the same
step.

Log levels carry that split. ERROR means an operator must act: a lost or
winnerless dispute, a won epoch that cannot settle, a rejected submission, a
batch the signer cannot cover, a call that reverts on consecutive ticks, a
torn snapshot, a worker exit, or a contract answer the node does not know (an
unknown bond disposition holds the epoch, and with it the next one). WARN
means the node carries on: the next tick retries, an action is skipped or
falls back, or best-effort work failed. INFO is protocol progress. Every
line's target is its module path, so `RUST_LOG` narrows the output to one
subsystem (`RUST_LOG=cartesi_rollups_prt_node::hero=debug`). Structured fields
are declined for lack of a consumer: the level and the target suffice.

## Storage

Everything lives under `--state-dir`:

```
state_dir/
  node.lock           held by the one node process using the directory
  db.sqlite3          main database (WAL mode, busy_timeout 10s)
  snapshots/0x<hash>/ machine snapshots, named by machine root hash
                      (the runner's boundaries and the disputes')
  <epoch_number>/     per-epoch dispute scratch dir
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
transaction closure. One node process owns a state directory: startup takes
an exclusive lock on its `node.lock` before the first write and refuses a
directory another process holds, or one whose filesystem cannot lock; SQLite
coordinates the worker threads. The lock does not cover the signer, which
must be exclusive on its own (transaction submission, below).

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
an undurable machine; it may replay at most one full batch. Dispute
positioning is the other publisher: it crosses whole windows from the nearest
boundary on the same clone chain and publishes only the disputed input's
boundary, which every later action of that dispute resumes from.

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

Publication adopts an existing content-addressed directory without rehashing
it. Every directory this process published was root-verified and synced
before its rename, so a crash-orphaned one is a complete, verified machine;
the lock excludes another node process, and every load verifies the root
against its row (the runner stops, dispute positioning skips the boundary).
External mutation of the store is unsupported, like manual database mutation.

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

Directory removal is not serialized with publication, and need not be: with
one process, a crossing never adopts a directory GC is removing. A Hero exists
only for the completion cursor's epoch `e`, after the runner rolled it, and is
dropped before the cursor advances, so crossings publish states of `e` only.
Meanwhile GC deletes epochs below both cursors and the gap rows of the
runner's later epoch, keeping every row of `e` and every later epoch's start.
Equal machine states occur only on contiguous runs of boundaries: a rejected
input restores its pre-input root, a terminal machine is a fixed point, the
delivery at the budget edge or to a halted machine changes the state once and
leaves it terminal, and mcycle otherwise grows. So a run from `e` to a swept
row passes through a kept start. A dispute boundary whose directory vanished
anyway (only external deletion does that) is skipped by positioning and
republished by the next crossing, unless it vanishes between that lookup and
the crossing's checkout, which panics. Revisit this if GC may ever sweep rows
of a live epoch, or a second publisher thread appears.

The runner captures all three settlement leaves from one final machine root,
checks their emulator proof metadata and Keccak openings, and verifies that
root again when publishing the next epoch's initial boundary. Capture does not
judge the machine state: a terminal app's epoch is still recorded and
defended. Only staging asks whether the state settles (a nonzero `iflags_Y`
and a manual `RX_ACCEPTED` HTIF reason, ignoring the response-length field),
and holds the epoch when it does not (epoch-lifecycle.md). The boundary row
and complete settlement row then
commit in the same SQLite transaction. Reads revalidate every persisted proof
against its final state so corruption fails before transaction staging.

One schema note to know about:

- The dispute tables (`sling_config`, `sling_nodes`) live in the main
  database. The quartet cache is restartable state, and `Hero` opens its own
  connection to the same file (shared file, disjoint tables, private
  connections). The per-epoch directory holds only scratch, the engine's
  machine work directories; dispute positioning publishes boundaries into
  the shared content-addressed store.
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
configuration (`--long-block-range-error-codes`). Decoded logs are sorted into
chain order (block, transaction and log index) before use: a response's order
is not guaranteed, and a reordered one would fail the index checks below on
every retry. A log without a block number fails the tick as an inconsistent
response. A successful response is otherwise trusted to contain every matching
log in its requested range; the node does not cross-check it against a second
provider. Input and epoch logs are the exception, because the node numbers
inputs itself and a missing one would silently shift every later commitment.
Each `InputAdded` must carry the next expected index, and a sealed epoch must
end at its upper bound.

A tick that finds new finalized blocks also reads, by number at the finalized
head `F`, the InputBox's input count for the application and the consensus's
current sealed epoch. When the stored totals already equal them, the tick
moves the watermark to `F` with no `eth_getLogs`, however far behind it is;
otherwise it skips the query whose total already matches, and the chunk that
reaches `F` must end at exactly those totals. A mismatch fails the tick before
anything is stored, and the next tick retries. Only `F`'s state is read, since
an earlier block's would need an archive node, so a chunk that ends before `F`
during catch-up is checked by contiguity alone: a log missing from its tail
surfaces only later, at the next log of its kind or at `F`, and then stops
ingestion until the state directory is rebuilt. Until `F` reaches the
consensus's deployment (an application deployed ahead of its consensus, or a
node started before its deployment finalized), the totals cannot be read and
the tick retries.

Ingestion starts at genesis, the earlier of the application's and the
consensus's recorded deployment blocks, so a new application on a long-lived
InputBox skips the InputBox's history. That is sound because the InputBox
refuses inputs for an address without code, the consensus seals epoch 0 in
its constructor, and the application binds its consensus only at
construction or within its deployment block; were it false, the first input
index or epoch number would not be 0 and ingestion would refuse it. Genesis
is read at latest, where a reorg before a new directory's first start may
still move the deployment lower, so the directory's watermark starts 128
blocks below genesis; with no application or consensus log before the
deployment, the margin only adds empty blocks to the first log query. The
initial hash is read at the consensus's deployment block (Process layout).
Both are `block.number` values, read as RPC block numbers, which is why the
node does not start on Arbitrum.

Ingestion commits at most 10,000 finalized blocks at a time, with their
watermark, so catch-up holds one chunk's inputs in memory and a restart
resumes from the last chunk. The bound is in blocks, not bytes: an adversary
paying for full blocks of inputs can still fill a chunk. Each chunk end is a
tail the totals cannot check, so during catch-up a provider that drops a
chunk's last input hits the stall above. While catching up, the epoch manager
may take a settled historical epoch for the current one until its successor's
seal arrives in a later chunk; the actions it plans for it revert at
estimation and are skipped with warnings.

The deadline-sensitive tournament reader holds one recursive, event-derived
`Dispute` through finalized `F`, in memory only. Each tick recursively extends
every tournament's local event stream through `F`, applying events one at a
time in log order, and only then replaces the Solid value. The fold does not
re-prove what the contracts guarantee, so it cannot stall on a sequence they
can emit: it rejects only an event it cannot apply without guessing (an
unknown match or commitment, a second join, a seal, advance or delegation of a
match that is no longer clocked, a second deletion). A commitment's standing
is derived from its latest match rather than tracked. A new reader folds from
the root tournament's creation block, so a restart is a cold start: it
refetches the full finalized range of every tournament still live at the
finalized head once (a child resolved before it costs only its descriptor
read), which costs response-clock time on a long dispute, and a bad finalized
prefix (a provider fault or a mixed fork) does not survive it. A finalized
event that does not fold onto Solid (an omitted log surfacing at the match's
next event) drops Solid in process, and the next tick takes the same cold
path; transport, harvest and decode failures keep it and retry the range. A
missed seal or delegation of an engaged match on the Hero's path still folds,
but its pinned phase read contradicts the match's folded status and fails the
Hero's tick, which then drops Solid the same way; a Foam tail that lags its
head costs one such refold. Any other omission that still folds, such as a
missed advance, or a missed join until a match pairs it, stays silent, and one
may surface too late: a missed creation of the Hero's own match, when the Hero
moves first, fails to fold only at the opponent's timeout deletion. Log
completeness is a trusted RPC property.

After Solid advances, the reader samples latest `H`, deep-clones Solid, and
recursively extends the clone over the numeric range `F + 1..H`. This latest
quantum foam is used once and dropped. It is never promoted, reverse-applied,
or compared with the previous tick. A tail log at `H`'s height must carry
`H`'s hash, as a finalized log at `F` must carry `F`'s, so a tail served from
another fork fails whenever `H` itself holds a tournament log. Ancestry below
`H` is not proven, by decision: walking parent hashes would cost one header
read per tail block, and a mixed tail is only a stale observation. A reorg or
mixed tail may reject the working tree, delay one action, or propose a stale
mutation. Contract mutators revalidate every transition, the lane skips a call
that reverts at estimation, and the next tick starts again from Solid.
Oversized ranges use the same binary range partitioning as other log
ingestion.

Events own tournament structure, commitment placement, match lifecycle, and
the inclusive block at which a clock-bearing match can be eliminated. Point
reads add only facts events do not carry: one immutable descriptor when a
tournament is discovered, one current standing per reachable tournament, and
the phase payload for each engaged match on the Hero's one recursive path.
A match resolution drops its child subtree, so the reader stops fetching the
child's stream, even for the range in which the parent resolved: nothing reads
a resolved child, and bond recovery walks the tournaments through its own
`NewInnerTournament` logs.
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

The Hero's machine work runs inside the manager's tick: commitment builds
while it assembles its path, proofs and descents while it prepares. It hands
the runtime worker off, so the reader and runner keep running, and nothing
deadline-bearing waits on the manager meanwhile. That rests on the
single-path Hero, not on a test: it has one engaged match per level, and a
cold build starts only after the seal that created its level mined, so none
of its own actions is pending; settlement is planned only after a win; and
refunds have no deadline (`tryRecoveringBond` has no time arm). A tick whose
assembly ran machine work observes the chain again before planning, once,
and that assembly reuses the build: the action, its head, the join's Solid
and any cleanup come from a view newer than the build, so a child that
finalized meanwhile is joined at once. A stop request cuts the work short
(Process layout). Two cases do put a build on the Hero's clock: a fresh state
directory while a dispute is engaged rebuilds every engaged level's
commitment, so upgrade or rebuild between disputes; and a reorg that drops a
seal mid-build leaves the node silent until the build ends. The tick's refund
scan keeps the finalized head sampled before the build, so on a pruned
provider it may fail once after a long build and retry on the next tick.

The lane is stateless. For every submission it reads the account's mined nonce
at Latest, obtains a fresh EIP-1559 fee estimate, and signs the batch at
consecutive nonces from that base. It submits each raw transaction to the
configured endpoint in order; a rejected submission does not discard the tail.
It does not wait for a receipt. Each gas limit is the estimate at latest plus
half again, at least 150,000: a join or win that finds a rival's commitment
dangling at inclusion takes the pairing branch, which the harness measured at
117,262 gas over the estimate, 70% of the cheapest join's estimate. The limit
stops at the EIP-7825 cap when the estimate fits under it, so the padding
never makes an admissible call inadmissible (a fork that lifts the cap leaves
the clamp conservative, never harmful); estimation failing other than by a
revert falls back to 15M. A call that already reverts at latest is not sent:
it costs nothing, and the lane warns with its revert reason. The manager logs
an error when the same call (verb, target and calldata) is skipped on
consecutive ticks, since the node keeps planning a step it cannot take; one
skip is routine with several honest nodes on one commitment, when another
node's copy of the step mines between this node's read and its estimate. The
node harness fails on any honest skip. Already-known transactions, underpriced
replacements, and stale nonces are ordinary retry states; every later tick
rebuilds intent from fresh observation. The mempool or a separately
configured revert-protecting endpoint arbitrates races and duplicates. The
lane observes no receipts, so a call that passes its estimate and loses a
race before inclusion is paid for. Every contested step races among the
honest nodes that share a commitment, so each may pay for the reverts of
steps another won, a reverted leaf proof's calldata included. A
revert-protecting endpoint behind `--web3-submit-rpc-url` avoids that cost;
the node recommends one and does not require it.

A slot the pool turns down on price is signed once more at the quote's max
fee with the tip raised to it. geth replaces only on 10% more of both fees,
and the quote's max fee is twice the latest base fee plus the market tip, so
the retry displaces any pending transaction the base fee has outrun, which a
fresh quote with a flat market tip could not. A pending transaction that
survives the retry has a fee cap above 1.8 times the latest base fee, so it is
includable and is waited out: a changed intent behind it costs at most that
transaction's inclusion and a paid revert. The retry has costs. A replaced
slot pays its full max fee, and the excess over the refund price (base fee
plus 10 gwei, dispute-game.md) is not refunded. A healthy pending transaction
is replaced too once the quote's max fee has risen 10% since it was signed,
which ordinary rising congestion does. The retry ignores intent: when a
transient Hero planning failure shrinks a wave to its recoveries, a recovery
may displace the pending Hero action at the same nonce for a tick. A full
pool or a minimum tip (a bare "transaction underpriced") takes the same retry
with a warning, and logs an error when the retry is refused too.

The signer must be exclusive to one node instance. A pool admits a batch only
while the balance covers every gas limit at its max fee plus its value, join
bonds included. After its sends the lane reads the balance and logs an error
on each tick whose batch reserves more; the check is advisory, since holding a
dispute step is the stall, and it speaks on the batch's first tick, which
matters behind a private relay that accepts an unaffordable batch silently.
The reserve is a lower bound (transactions an earlier, longer batch left
pooled count too), and a slot on the 15M fallback inflates it. The
provisioning floor and its assumed peak fee live in the node README.

## Performance stance

The node claims only that it adds no work over the emulator's own. Whether
a geometry fits an application on given hardware is measured with the
emulator (docs/measurements/constants.md) and sized by the operator; the
node never refuses to run for performance. CI gates deterministic work
counts, never time (`engine/spec.rs`: a leaf build runs each ustep once, an
idle stretch costs one captured cycle per stratum span (at most 256 per
build), folded spans cost no machine work; a join
replays the disputed input's prefix once for the build and once per stored
fanout stratum, five times at height 37, within the measured overhead).
Before releases and hot-path changes, `just measure-node-vs-emulator` times a
cold join and a deep proof against the emulator on the same host, with peak
RSS and disk (docs/measurements/node-vs-emulator.md). At runtime the Hero
logs each action's preparation time, commitment builds included.

## Known debts

None open. A new debt is listed here with the doc that owns its reasoning.
