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

`cartesi-sling-node` (binary) runs three workers on one tokio
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
between one big cycle and one input window). It does not judge whether a table
can be built in time and does not pin or check `T`: sizing the leaf to `T` is
the operator's and the geometry's concern. It refuses to start unless
`CartesiStateTransition.CM_MARCHID()` equals the `CM_MARCHID` exported by the
linked Cartesi Machine library and `UARCH_PRISTINE_STATE_HASH()` equals the
library's pristine uarch hash (computation-hash.md says how it is read). It
then probes the data directory, creating nothing. Unless the probe finds it
seeded, it inspects the `--template-path` image (one private load: its root
hash; its hash function, which must be Keccak-256; its uarch state's hash,
which must be that pristine uarch hash; and whether it is paused at a manual
accepted yield), and the root hash alone decides which epoch the image
starts. The consensus's initial hash makes it the template, starting epoch 0
with no further read. Otherwise it must be the state the current sealed epoch
k starts from, `getLastFinalizedMachineMerkleRoot(app)` beside
`getCurrentSealedEpoch()`, both read by number at a finalized head sampled
just before, and it starts epoch k. Only that last settled state is accepted:
an older one would need a log search, and an image stays current for at least
a root allowance. Any other image is refused with exit 30, naming
`snapshots/0x<hash>`, where every node working on epoch k keeps the state to
take; a state settled after the sampled head is refused until its settlement
finalizes, since the finalized-only reader could not execute its epoch
anyway. The root hash comes from the image's stored hash tree, so a seed
image is trusted like the template: take it from a store you trust. A
matching image paused elsewhere is still refused: the engine starts every
epoch from a state awaiting input, so the node could not defend any of its
epochs (for a settled state this cannot happen, since staging requires the
same yield). Only then does it take the data-directory lock and open the
directory, which decides again whether it is seeded. A seeded directory is
compared with its `sling_config` pins (app, chain, consensus, the
deployment's initial hash, emulator and table) before anything is written.
The pin holds the deployment's initial hash whatever image seeded the
directory, so a restart compares pins and never reads `--template-path` or
the moving last settled state, and a moved image or one an emulator upgrade
can no longer load does not stop it. A mismatch names the flag to fix
(`--app-address`, `--blockchain-id`), calls the directory another
deployment's or an old one (the initial hash), or asks for a rebuild
(consensus, emulator, table). A new directory is seeded in one transaction:
the initial watermark, the seed epoch's start boundary, the completion cursor
at that epoch and the pins. So a deployment or flag these checks reject cannot
create or alter local state. The runner samples each window at the pinned
root stride. Other operator mistakes (an unknown chain id, an unreadable or
invalid key, an endpoint on another chain, an address that is not a Dave
application) are errors that name their flag too, and add no key material;
no error quotes an endpoint's URL (RPC client). An unknown chain id and an
endpoint on another chain are terminal (exit 30). Before any read above,
startup asks each endpoint its chain, once, and one that does not answer
fails the start (exit 1, which the supervisor retries): the workers build
their clients without asking again. The
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
The runner stops before its next input or epoch roll and drops an unfinished
batch, which a restart replays as after a crash. The manager finishes its
tick, so an action whose preparation completed still goes out with the tick's
recoveries, but the Hero's machine work stops early: positioning before its
next crossed input, and a stride-0 build at least `c + 8 = 28` high (the leaf
level of a two-level table) before its next bottom-stratum span. Finished
spans stay in the quartet cache, and the restarted node's build resumes after
them. Everything else runs to completion: one input's replay, a recompute
below that height, the leaf and middle builds of the three-level table
(seconds to minutes, unmeasured), and the tick's RPC calls (the recovery scan,
estimation, submission). So a stop can drop a due action's preparation, which
the restarted node prepares again after its Hero refolds the live tournaments'
logs.

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
  warning, and an error once the same call has been planned for G. It does
  nothing against omission or a lying read: a missing finalized log or a
  false standing can make the Hero wait instead of act, and nothing reverts.
  The fold keeps the guards that stop it from guessing; tournament-log
  completeness and truthful pinned reads otherwise stay trusted RPC
  properties.
- When the two conflict, split the check: keep a panic only for what
  corruption alone can reach, and move what chain data can reach off the
  clock path. The terminal-application fix (cartesi/dave#287) did this after
  a terminal application panicked every node at the roll, which would have
  let a fabricated claim win uncontested.

Apart from the two accepted halts and the trust model below, chain data
reaches no panic on the dispute path. Once a wrong epoch has settled, the Hero
stops the node (exit 30) on a root that starts from a state it did not
compute, an already-defeated protocol; it reaches that root only after the
settled epoch's refunds and sentry vote. Chain-reported coordinates reach the engine only
through validators that accept everything the contracts produce. The observer
checks each match against its tournament's descriptor (height, position,
alignment, cycle); a bisecting match must stand above height 1, since
advancing opens the children of the node below the contested one; a level's
base cycle must be aligned to its span, and a delegated child must sit one
level below its parent, on one of the parent's leaves; and every level's
stride and height must match the pinned table, which tiles the machine
coordinate.
Nothing checks that the root's base cycle is 0; the trusted factory sets it.
The observer's standing decoder likewise fronts its own `expect` on
parent-match data. The engine's asserts behind them
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
well-formed requests (a template preset with a malformed request stops the
node at startup, in `Template::inspect`, before anything is written, while a
guest's oversized yield throws and the runner retries it forever). One failed
standing read or finalized fold fails the Hero's whole tick, and a failed
refund scan holds the epoch's completion; an audit of the node's panics and
retry loops found no data the contracts can produce that fails any of them
deterministically.

Workers retry a failed tick with a warning that carries the whole error chain:
a transient provider or storage error costs one polling interval. The node
has one paging rule (`escalation.rs`): a failure that would cost a dispute if
it persisted logs WARN while it lasts and ERROR once it has lasted G, the
5-minute response window every action is budgeted to land in. Past G a due
response draws on C, and a transient blip never pages. The rule covers the
reader's and the runner's ticks, the manager's tick and its dispute,
settlement and refund planning, a sealed epoch the runner has not finished,
and each call the manager plans: planning reads latest and drops a call once
it lands, so a call planned for G has not landed (it reverts at estimation,
with the reason in the error; the submit endpoint does not answer; a relay
holds or dropped it; it is outbid; or it mines without effect). G is
hardcoded, since the node knows no block time to convert the table's budgets;
revisit it if a deployment's G departs from 5 minutes. A read endpoint that
stops following the chain fails nothing (it answers consistently with its old
head), so the reader also logs ERROR on
every tick whose latest block is older than G; a stalled provider is outside
the trust model, so it is reported, not worked around. An ingestion check
that keeps failing means the provider keeps
omitting logs (point the node at a complete one), or a stored chunk lacks
one: its page names both remedies. That is the one stall a retry never heals:
a log missing from the tail of a catch-up chunk (rebuild the data directory).
A tournament event that does
not fold onto the reader's finalized prefix, or a phase read on the Hero's
path that contradicts it, drops the prefix, and the next tick refolds from
the root's creation block as a restart would; any other omitted log that
still folds is not detected (RPC completeness is trusted). Asserts are for
states reachable only through a node bug, corrupt local state, a broken
trusted assumption, or an already-defeated protocol; there, stopping loudly
is the alarm. A panic stops every worker, refunds included (`lib.rs`,
`worker_failure`), and a restart re-plans the same step.

The exit status tells a supervisor which of these happened (`fatal.rs`), with
the numbers of the sequencer's contract: 0 a requested stop, 1 any other
error (restart with backoff), 2 a usage error, 30 terminal (a flag, the
seed image, the deployment or the settled chain disagrees with the node: do not
restart, an operator must act), 40 rebuild the data directory (its store
format, commitment semantics, emulator, consensus or geometry is another). A panic
exits 101: restart with backoff and page, since a restart cannot make an
invariant violation worse and may clear a nondeterministic one while a clock
runs. The sequencer aborts on its panics instead, because its diagnosed
faults cannot heal. Every exit logs its cause at ERROR, panics included (a
panic hook), and a failure during a signal-requested drain still fails the
exit status.

Log levels carry that split. ERROR means an operator must act: a lost or
winnerless dispute (a loss names its case: elimination, another class's child
win, a root won with this node's final state, or a divergence), an obligation
the local commitment already missed (joins closed before it joined, its clock
expired, its match or its match's child is eliminable), a won epoch that
cannot settle, a submission the endpoint rejected (one it did not answer is
WARN until its call pages), a batch the signer cannot cover, a failure or a
planned call that persists past G (the paging rule above), a torn snapshot, a
worker exit, or a contract answer the node does not know (an unknown bond
disposition holds the epoch, and with it the next one). WARN
means the node carries on: the next tick retries, an action is skipped or
falls back, or best-effort work failed. INFO is protocol progress. Every
line's target is its module path, so `RUST_LOG` narrows the output to one
subsystem (`RUST_LOG=cartesi_sling_node::hero=debug`). Structured fields
are declined for lack of a consumer: the level and the target suffice.

## Storage

Everything lives under `--data-dir`:

```
data_dir/
  node.lock           held by the one node process using the directory
  db.sqlite3          main database (WAL mode, busy_timeout 10s)
  snapshots/0x<hash>/ machine snapshots, named by machine root hash
                      (the runner's boundaries and the disputes'); the
                      database stores hashes, never paths, so a stopped
                      node's directory may move
```

The storage module follows the sequencer's shape: `open.rs` owns connections
(WAL, `synchronous=FULL`, busy timeout) and the `read`/`write` closure
helpers (Deferred vs
Immediate); writer roles live in per-role files - `ingest.rs`
(blockchain-reader), `advance.rs` (machine-runner), `dispute.rs` (player), and
`completion.rs` (epoch-manager) - `snapshots.rs` is the boundary store (every
machine store, load, and clean), and `queries.rs`
is the role-free read surface. Every public operation is one
transaction closure. One node process owns a data directory: startup takes
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
no migrations. On an empty database, startup applies that file once and
atomically stamps two hand-bumped versions from `storage/sql/schema.rs`: the
store format (`STORE_FORMAT`, the layout of the data directory) and the
commitment semantics (`COMMITMENT_SEMANTICS`, leaf values and transition
shapes). On later launches it executes no DDL: both must match the running
binary, or startup refuses the data directory with exit status 40. A test pins
the schema file's hash, so every edit of it decides whether to bump the store
format; manual database mutation remains unsupported rather than continuously
audited.

The epoch-completion cursor is not bound to a signer: recovery pays the
configured signer's bonds, and a previous signer's bonds stay recoverable by
anyone. A data directory of another store format or commitment semantics is
rebuilt from the chain and a seed image, never migrated.

Main schema (`storage/sql/schema.sql`):

- `node_metadata(store_format, commitment_semantics)` - the store's identity
- `epochs(epoch_number, input_index_boundary, root_tournament, block_created_number)`
- `inputs(epoch_number, input_index_in_epoch, input)`
- `latest_processed(block)` - singleton; last finalized block ingested
- `epoch_completion` - singleton; next unfinished epoch, from the seed epoch
- `settlement_info(epoch_number, computation_hash, final_state, data block and
  sibling blobs for iflags_Y, HTIF tohost, and the TX buffer)` - the TX data
  block is the outputs Merkle root
- `epoch_snapshot_info(epoch_number, input_number, state_hash)` - which
  machine sits before each stored input; the seed image is its epoch's start

Every table belongs to one of four mutation classes - append-only
log, write-once cell (equal rewrites absorbed, disagreements fatal),
monotonic watermark, prunable derived store - and its writer in
`storage/` keeps the class: the logs check their sequence and return
typed errors; the write-once rows written while the node runs
(settlements, boundaries, quartet nodes) compare with the stored row and
panic on a disagreement, so nondeterminism reaches the loud exit instead
of a retry loop; the identity rows (`node_metadata` and the engine
config) are written once at seeding and checked at startup, which refuses
a mismatch with exit status 30 or 40; the watermark only rises; only
collection removes rows.
`sql/discipline.rs` pins where in-place writes and deletes may appear.
GC releases boundary rows and, in the same transaction, finds the states no
remaining row names; their directories are removed only AFTER that
transaction commits: a crash may orphan a directory, never dangle a row.

The manager drops an epoch's Hero before recording completion. The runner
collects released snapshots and dispute rows while planning its next batch,
including idle polls. It collects only epochs below both the completion cursor
and its newest machine epoch. Neither chain progress nor manager catch-up can
delete the runner's newest durable boundary.

Directory removal is not serialized with publication, and need not be: with
one process, a crossing never adopts a directory GC is removing. A Hero exists
only for the completion cursor's epoch `e`, after the runner rolled it, and is
dropped before the cursor advances, so crossings publish states of `e` only.
Meanwhile GC deletes only epochs below both cursors, keeping every row of `e`
and of every later epoch.
Equal machine states occur only on contiguous runs of boundaries: a rejected
input restores its pre-input root, a terminal machine is a fixed point, the
delivery at the budget edge or to a halted machine changes the state once and
leaves it terminal, and mcycle otherwise grows. So a run from `e` to a swept
row passes through a kept start. A dispute boundary whose directory vanished
anyway (only external deletion does that) is skipped by positioning and
republished by the next crossing, unless it vanishes between that lookup and
the crossing's checkout, which panics. Revisit this if GC may ever sweep rows
of a live epoch, or a second publisher thread appears.

The runner loads the epoch's final boundary, its root verified against the
row, and captures all three settlement leaves from that root, checking their
emulator proof metadata and Keccak openings. Capture does not judge the
machine state: a terminal app's epoch is still recorded and defended. Only
staging asks whether the state settles (a nonzero `iflags_Y` and a manual
`RX_ACCEPTED` HTIF reason, ignoring the response-length field), and holds the
epoch when it does not (epoch-lifecycle.md). Finishing an epoch changes no
machine state, so the next epoch starts from the same snapshot: its `(e+1, 0)`
row and the settlement row commit in one SQLite transaction, which first
re-checks that the cursor still ends the sealed epoch. Reads revalidate every
persisted proof against its final state so corruption fails before
transaction staging.

One schema note to know about:

- The dispute tables (`sling_config`, `sling_nodes`) live in the main
  database. The quartet cache is restartable state, and `Hero` opens its own
  connection to the same file (shared file, disjoint tables, private
  connections). Dispute positioning publishes boundaries into the shared
  content-addressed store.
  Hero construction materializes nothing: `DisputeSource::on_store` reads the
  input count, the window-root quartet rows prepaid by the machine runner, and
  the final boundary hash. Below window granularity, disputes replay the
  machine like any nested level; leaf runs are not persisted. Completed-epoch
  collection deletes released `sling_nodes` rows, window roots included.

## RPC client

Every RPC client (`provider.rs`, `create_client`) keeps reqwest's defaults:
HTTP/2 where TLS negotiates it, which every hosted provider does, and
HTTP/1.1 on plain http. Four settings are the node's own. A 20 s timeout
bounds each attempt, connect through body. A 30 s HTTP/2 keep-alive PING
with a 10 s timeout is the only thing that evicts a silently dead shared
connection, since a request timeout does not. A 60 s idle timeout closes
pooled connections before nginx's or geth's server-side idle close.

The retry layer resends a rate-limited request at most twice, a second
apart, which clears a per-second cap that rejects part of a tick's
concurrent reads. It never resends a timeout or a connection error. It
also skips two resends: a wait the server asks for beyond 5 s, which the
next tick serves instead, and Infura's result-count rejection, which reuses
its rate-limit code (-32005) but clears only by splitting the range. The
skipped wait is the hint the layer itself sleeps on, so no resend waits
longer than 5 s. alloy drops a `Retry-After` header that comes with a
JSON-RPC error body, so such a 429 is resent at the one-second backoff. The
tick is the retry for everything else. A layer strips the endpoint's URL,
which often carries an API key, from every transport error before any
caller logs it.

The submit endpoint shares this configuration on purpose: resending the same
raw transaction on a rate limit is idempotent, and the 20 s timeout only
bounds a hang, while a shorter one would make a slow relay fail every send.

## Chain ingestion stance

Epoch and input ingestion consumes logs only up to the chain's finalized block
(`BlockNumberOrTag::Finalized`). Finality is trusted and those rows are never
rolled back. Any failed `eth_getLogs` over more than one block is split in two
and retried: range, result-count and response-size caps and timeouts clear by
narrowing, and providers' codes for them vary and overlap with rate limits. A
single block's logs are bounded by its gas, so a failure there fails the tick;
a persistent error therefore costs about log2(range) + 1 sequential queries,
never the whole range tree. Decoded logs are sorted into
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
ingestion until the data directory is rebuilt. Until `F` reaches genesis (a
node started before its deployment finalized), the consensus has no code to
answer the totals, and ingestion waits without error.

Ingestion starts at genesis, the earlier of the application's and the
consensus's recorded deployment blocks, so a new application on a long-lived
InputBox skips the InputBox's history. That is sound because the InputBox
refuses inputs for an address without code, the consensus seals epoch 0 in
its constructor, and the application binds its consensus only at
construction or within its deployment block; were it false, the first input
index or epoch number would not be 0 and ingestion would refuse it. Genesis
is read at latest, where a reorg before a new directory's first start may
still move the deployment, so startup samples the finalized head before it
reads the deployment blocks and seeds the watermark at the lower of genesis
minus one and that sample. A deployment finalized at the sample cannot move,
and one that was not can reorg only into blocks above it, so epoch 0's seal
stays above the watermark; with no application or consensus log before the
deployment, a lower start only adds empty blocks to the first log query. The
initial hash is read at the consensus's deployment block (Process layout).
Both are `block.number` values, read as RPC block numbers, which is why the
node does not start on Arbitrum. Ingestion starts at genesis whatever the
seed: a directory seeded at epoch k still stores every earlier epoch and
input, since the node numbers inputs from the application's first, and
never executes them.

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
refetches the finalized range of every tournament still live at the
finalized head once, each from its own creation block (a child resolved
before it costs no read of its own), which costs response-clock time on a
long dispute behind a provider that caps log ranges, and a bad finalized
prefix (a provider fault or a mixed fork) does not survive it. A finalized
event that does not fold onto Solid (an omitted log surfacing at the match's
next event) drops Solid in process, and the next tick takes the same cold
path; transport, harvest and decode failures keep it and retry the range. A
missed seal or delegation of an engaged match on the Hero's path still folds,
but its pinned phase read contradicts the match's folded status and fails the
Hero's tick, which then drops Solid the same way; a lagging or mixed Foam
tail costs one such refold. Both drops repeat while their cause persists (a
provider that keeps omitting the log, or a node bug): every tick then refolds
and fails with the same warning, adding reads to a stall that exists anyway.
Any other omission that still folds, such as a missed advance, a missed join
until a match pairs it, or a missed deletion of a delegated match (the Hero
reads nothing there), stays silent, and one may surface too late: a
missed creation of the Hero's own match, when the Hero moves first, fails to
fold only at the opponent's timeout deletion. Log completeness is a trusted
RPC property.

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
the inclusive block at which a clock-bearing match can be eliminated, and a
child's immutable descriptor arrives in its `NewInnerTournament` event, which
the factory projects from the child's clone arguments. Point reads add only
the root's descriptor on a cold fold (the node reads no factory logs), one
current standing per reachable tournament, and the phase payload for each
clocked or sealed-leaf match the Hero engages on its one recursive path.
A match resolution drops its child subtree, so the reader stops fetching the
child's stream, even for the range in which the parent resolved: nothing reads
a resolved child, and bond recovery walks the tournaments through its own
`NewInnerTournament` logs.
Standing calls use bounded concurrency. A clock-bearing Hero match needs a
timeout classification and one phase projection; a delegated parent needs no
read, since the observer bounds its child's event-borne descriptor by the
parent's. These reads are pinned to `H`. The observer narrows ABI
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
The cursor starts at the directory's seed epoch: a directory seeded at epoch k
owns k and later epochs and never touches an earlier one, so bonds its signer
holds there are the operator's (node README). Until epoch k's seal is
ingested, the manager idles.

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
of its own actions is pending; settlement is planned only once the root has a
winner; and
refunds have no deadline (`tryRecoveringBond` has no time arm). A tick whose
assembly ran machine work observes the chain again before planning, once,
and that assembly reuses the build: the action, its head, the join's Solid
and any cleanup come from a view newer than the build, so a child that
finalized meanwhile is joined at once. A stop request cuts the work short
(Process layout). Two cases do put a build on the Hero's clock: a fresh data
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
up to 110,161 gas over the estimate, 66% of the cheapest join's. The limit
stops at the EIP-7825 cap when the estimate fits under it, so the padding
never makes an admissible call inadmissible (a fork that lifts the cap leaves
the clamp conservative, never harmful); estimation failing other than by a
revert falls back to 15M. A call that already reverts at latest is not sent:
it costs nothing, and the lane warns with its revert reason. The manager logs
an error, with that reason, once the same call (verb, target and calldata)
has been planned for G, since the node keeps planning a step it cannot take;
one skip is routine with several honest nodes on one commitment, when another
node's copy of the step mines between this node's read and its estimate. The
node harness fails on any honest skip. Already-known transactions, underpriced
replacements, stale nonces and sends the endpoint did not answer are ordinary
retry states; every later tick rebuilds intent from fresh observation. The
mempool or a separately configured revert-protecting endpoint arbitrates
races and duplicates. The lane observes no receipts, so a call that passes
its estimate and loses a race before inclusion is paid for. Every contested
step races among the honest nodes that share a commitment, so each may pay for
the reverts of steps another won, a reverted leaf proof's calldata included.
An adversary who orders transactions can impose the same cost on every honest
action by landing an identical copy first, up to the EIP-7623 floor of a
maximum-input leaf proof, about 3.76M gas, at no extra bond
(reviews/2026-10-13-prt-cyber-verification, L-06). A revert-protecting
endpoint behind `--blockchain-http-submit-endpoint` avoids that cost. The node
recommends one and warns at startup without one, on any chain but anvil's; it
will require one only once a relay passes
[runbooks/submit-relay.md](runbooks/submit-relay.md), and until then a
production deployment should treat it as required.

A slot the pool turns down on price is signed once more at the quote's max
fee with the tip raised to it. geth replaces only on 10% more of both fees,
and the quote's max fee is twice the latest base fee plus the market tip, so
the retry displaces any pending transaction the base fee has outrun, which a
fresh quote with a flat market tip could not. On a public pool, a pending
transaction that survives the retry has a fee cap above 1.8 times the latest
base fee, so it is includable and is waited out: a changed intent behind it
costs at most that transaction's inclusion and a paid revert. The retry has
costs. A replaced slot pays its full max fee, and the excess over the refund
price (base fee plus 10 gwei, dispute-game.md) is not refunded. A healthy
pending transaction is replaced too once the quote's max fee has risen 10%
since it was signed, which ordinary rising congestion does. The retry ignores
intent: when a transient Hero planning failure shrinks a wave to its
recoveries, a recovery may displace the pending Hero action at the same nonce
for a tick. A full pool or a minimum tip (a bare "transaction underpriced")
takes the same retry with a warning, and logs an error when the retry is
refused too.

Behind a revert-protecting relay, waiting out does not hold for a pending
transaction that can no longer succeed: the relay never includes it, so it
holds its nonce until the relay admits another transaction at that nonce,
which the next tick's re-sign then is, or drops the held one. No relay
documents the first, and Flashbots Protect documents the second after 25
blocks by default; runbooks/submit-relay.md measures both. A race between
honest nodes never holds its winner: the winner's nonce advanced, so it
defends the next step while the losers wait. The commitment waits only when
every honest transaction for a step is doomed at once: by an adversary's
copy, timed blind into the send-to-inclusion window the relay hides, or by the
opponent's expiry overtaking a leaf proof, whose fallback timeout claim then
queues behind it (todo.md, the timeout-claim item). Each such occurrence lands
the next action up to the hold R later, about R + one polling interval +
inclusion - G beyond G, drawn from C: about 40 s with Flashbots' default 25
blocks. The draw is bounded by R and documented rather than engineered away,
so the lane stays stateless; a relay whose hold has no bound does not qualify.

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
a geometry fits an application on given hardware is measured on the node's
own leaf path (the node crate's `measure.rs --constants`,
docs/measurements/constants.md) and sized by the operator; the node never
refuses to run for performance. CI gates deterministic work
counts, never time (`engine/spec.rs`: a leaf build runs each ustep once, an
idle stretch costs one captured cycle per stratum span (at most 256 per
build), folded spans cost no machine work; a join
replays the disputed input's prefix once for the build and once per stored
fanout stratum, five times at height 38, within the measured overhead).
Before releases and hot-path changes, `just measure-node-vs-emulator` times a
cold join and a deep proof against the emulator on the same host, with peak
RSS and disk (docs/measurements/node-vs-emulator.md). At runtime the Hero
logs each action's preparation time, commitment builds included.

## Known debts

None open. A new debt is listed here with the doc that owns its reasoning.
