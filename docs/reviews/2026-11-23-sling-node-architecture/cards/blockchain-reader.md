# Card: blockchain reader

Scope: `cartesi-rollups/node/src/blockchain_reader/mod.rs` (production: lines
1-648 less the test-only `with_chunk_blocks` at 314-319, plus 653-836; about
827 lines, of which `AddressBook` and seeding are 26-285, about 260);
`cartesi-rollups/node/src/storage/ingest.rs` (production 1-129);
`cartesi-rollups/node/src/blockchain_reader/test_utils.rs` (230 lines, all
test-only, `mod.rs:650-651`, also used by `src/args.rs` and `src/harness/mod.rs`
tests). Tests: `mod.rs:838-1904`, `ingest.rs:130-258`.

## Possible correctness bug

None met. I traced the numbering walk (`mod.rs:580-647`, `769-836`) through
the stored-eager-split, late-seal, empty-epoch and seal-in-same-chunk cases,
and the tail-stall path (Q2 below). Every case either numbered correctly or
failed the tick before commit. The one exception, a dropped seal at a catch-up
tail, commits wrongly-epoched rows before it stalls (Invariant 6). It cannot
settle anything.

## Owns

- The `inputs`, `epochs` and `latest_processed` rows, as their only runtime
  writer (`ingest.rs:21-33`). Seeding also writes `latest_processed`, once,
  before the workers start (`storage/open.rs:358`).
- The input-to-epoch assignment: global index -> (epoch, position)
  (`mod.rs:580-647`, `769-836`), including the eager 2^24 split of an open
  epoch before its seal (`mod.rs:633-642`, `794-797`).
- Log completeness for the two event kinds (`LogCheck`, `mod.rs:689-718`).
- Two endpoint-health pages: stale latest and stale finality
  (`mod.rs:364-399`). These are the node's only callers of
  `Chain::latest_age` and `finalized_age` (grep of `src/`).
- Deployment discovery and seed-epoch selection (`AddressBook`,
  `mod.rs:26-285`). These are startup concerns: they are called from
  `args.rs:452-497`, never from the reader loop.

Process memory carried across ticks: `failing: Persistence` (`mod.rs:322`),
which gates paging only, and `watch_head_age` (`mod.rs:325`), which is config.
The struct holds only config (`mod.rs:297-302`). All numbering state is
re-read from the database each tick: `total_input_count` (COUNT(*),
`storage/queries.rs:111-116`), `last_input` (`queries.rs:105`) and
`last_sealed_epoch` (`queries.rs:47-61`), at `mod.rs:470-474`, `497-498` and
`586-590`. Losing the process costs nothing but the paging timer.

## Takes

- From `Chain` (`chain.rs`):
  - `finalized_head().number` (`mod.rs:419`); the hash is discarded.
  - `decoded_logs::<E>(address, topic1, from, to)` (`mod.rs:524`, `567`).
    `Chain` bisects failed ranges (`chain.rs:225-246`) and sorts logs into
    chain order after refusing a log without a block number
    (`chain.rs:194-203`).
  - `latest_age` and `finalized_age` (`chain.rs:87-107`).
  - It trusts that a successful response holds every matching log, has no
    forged payload, and comes from the requested emitter.
- From the chain, through point reads at `F` by number (`mod.rs:664-684`):
  `IInputBox.getNumberOfInputs(app)` and
  `DaveConsensus.getCurrentSealedEpoch().epochNumber`. Trusted to be the state
  at `F`.
- From storage, re-read each tick: the watermark (`mod.rs:420`), the stored
  totals (`mod.rs:468-476`), the last stored input and the last sealed epoch.
  It trusts its own past writes. They were validated on insert
  (`ingest.rs:76-81`, `112-118`).
- From the engine: `Structure::PRODUCTION.max_inputs()` = 2^24
  (`mod.rs:510`, `engine/structure.rs:62-64`). It trusts that this equals
  DaveConsensus's `MAX_INPUTS_PER_EPOCH`
  (`cartesi-rollups/contracts/src/DaveConsensus.sol:39`). Seals check that
  equality lazily (`mod.rs:604-617`, `798-802`).
- From config: `AddressBook` (`app`, `consensus`, `input_box`,
  `genesis_block_number`), `sleep_duration`, and `sling_config().chain_id`
  against `args::ANVIL_CHAIN_ID` (`mod.rs:325`).

## Gives

- `inputs(epoch_number, input_index_in_epoch, input)`. It promises dense
  global numbering from index 0, positions dense within each epoch, at most
  2^24 per epoch, and every sealed epoch's rows ending exactly at its
  `inputIndexUpperBound`. It also promises finalized-only data, never rolled
  back.
  - The runner reads only the epoch of its latest boundary
    (`storage/advance.rs:157-189`).
  - The runner's roll asserts boundary == count (`advance.rs:146-153`).
- `epochs(epoch_number, input_index_boundary, root_tournament,
  block_created_number)`, dense from 0 (`ingest.rs:112-118`).
  - `input_index_boundary` is the upper bound. The event's lower bound is
    dropped (`mod.rs:534-550`).
  - The manager reads the cursor's row (`queries.rs:33-45`) and the last row's
    `block_created_number` (`epoch_manager/mod.rs:194-196`).
  - The runner reads `epoch_is_sealed_in` (`advance.rs:135-144`).
- `latest_processed.block`, monotone (`ingest.rs:38-47`). Only the reader
  reads it.
- Startup only: `AddressBook::new`, `initial_watermark`, `seed_epoch`
  (`args.rs:452-497`).

## Invariants

1. The input index is dense. Each `InputAdded.index` equals the next
   expected one (`mod.rs:784-793`, typed `InputIndex`), seeded from the
   COUNT(*) of stored rows (`mod.rs:590`). Breaks: a dropped log silently
   shifts every later input and commitment. Pinned by
   `a_missing_log_fails_instead_of_shifting_later_inputs` (`mod.rs:1159`).
2. A sealed epoch ends at its bound (`mod.rs:821-831`, `SealedBound`). A seal
   older than the last stored input is re-checked by counting back over full
   eager windows (`mod.rs:603-617`). Breaks: wrong epoch membership, so a
   wrong computation hash. Pinned at `mod.rs:1031-1053` and `1382`.
3. At most 2^24 inputs per epoch (`mod.rs:798-802`). An open epoch splits at
   2^24 (`mod.rs:794-797`). This is not in SQL: `schema.sql:40-45` has no
   CHECK on the position. Breaks: an unrepresentable input coordinate in the
   engine. Pinned at `mod.rs:1107-1121`.
4. At `F` the totals equal the chain's: the input count and the last sealed
   epoch (`mod.rs:452-461`, `736-761`). Breaks: the tail omission in the final
   chunk goes undetected. Pinned at `mod.rs:1423-1450`.
5. Stored rows continue densely. `InputId::validate_next`
   (`storage/mod.rs:148-167`) allows any epoch jump that restarts at position
   0, so it does not see global indices; that is invariant 1's job. Epochs are
   numbered MAX+1 (`ingest.rs:112-118`, `queries.rs:152-156`). Breaks: gaps.
   Typed as `StoredInputs` and `StoredEpochs` (`mod.rs:712-716`).
6. One tick commits one transaction: the watermark, the inputs and the epochs
   together (`ingest.rs:27-32`), and that commit follows every await
   (`mod.rs:463-464`). A failed batch rolls back whole, pinned at
   `ingest.rs:180-194`. Caveat: a seal dropped at a catch-up chunk tail lets
   later chunks commit inputs into the eager epoch that the missing seal would
   have closed. The test comment at `mod.rs:1519-1525` describes exactly that
   row ("input 2, stored as epoch 1's third"). The stall comes later, at the
   next seal or at `F`. Nothing settles from it: `unfinished_epoch` needs the
   missing row (`queries.rs:33-45`).
7. Nothing is deleted from `inputs`, `epochs` or `latest_processed`. The
   discipline test pins the only DELETEs to `advance.rs` and `snapshots.rs`
   (`storage/sql/discipline.rs:46-53`). The only in-place UPDATE in this file
   is the watermark (`discipline.rs:37-44`).

## Concurrency and crash consistency

There is one async task (`lib.rs:88-98`) with its own connection. It is the
only runtime writer of its three tables. The runner and the manager read them
from their own connections.

The reader's reads within a tick are separate read transactions
(`mod.rs:420`, `470-474`, `497`, `586-590`). That is safe because nobody
else writes these tables, and the write re-validates against the database
inside its own transaction (`ingest.rs:66`, `112`).

A stop drops the tick in flight (`mod.rs:333-335`). Kill -9 at each step:
- Before the commit: nothing is written, and the restart refetches the same
  chunk.
- After the commit: the chunk is durable, and the restart resumes at its
  watermark.

Replaying a tick is harmless: the watermark is MAX (`ingest.rs:42`), and
duplicate rows fail the PK and continuity checks. Memory-only state is the
paging timer. Losing it delays a page by up to G and changes nothing else.

## What it knows about its neighbours

- Provider (`provider.rs`): nothing imported. The reader gets a
  `DynProvider` wrapped in `Chain` (`lib.rs:93`), and `chain.provider()` is
  used only for contract point reads (`mod.rs:181`, `666`, `672`). Needed.
- Chain facade (`chain.rs`): `Chain`, `finalized_head`, `decoded_logs`,
  `latest_age`, `finalized_age`. Needed. The `finalized_head` comment ("so logs
  at the durable boundary can be checked", `chain.rs:109-110`) describes the
  tournament reader. This reader drops the hash (`mod.rs:419`).
- Storage: the `Epoch`, `Input`, `InputId` and `StorageError` variants
  (`mod.rs:19`, `712-716`); the queries `total_input_count`, `last_input`,
  `last_sealed_epoch`, `latest_processed_block` and `sling_config`; and the
  writer `insert_consensus_data`. Needed. COUNT(*) as "next index" is a
  representational coupling: it requires every row since genesis (Q6).
- Engine: `Structure::PRODUCTION.max_inputs()` (`mod.rs:510`). This is needed
  knowledge, but it is the emulator constant that the contract also uses. The
  reader's dependency is on the cap, not on the engine.
- Runner: no import. The eager split exists for the runner
  (`mod.rs:633-634`).
- Epoch manager: no import. It consumes `block_created_number` and
  `root_tournament` (`epoch_manager/mod.rs:194-196`; recovery starts from
  "the ingested epoch root", `docs/epoch-lifecycle.md:204`).
- Escalation and args: `Persistence`, `PAGE_AFTER` (`mod.rs:6`) and
  `args::ANVIL_CHAIN_ID` (`mod.rs:325`). These are small, but a leak: the
  reader knows the dev chain id.
- Consensus and rollups ABI:
  - `IApplication.getOutputsMerkleRootValidator` and
    `getDeploymentBlockNumber` (`mod.rs:73-127`).
  - `DaveConsensus.getApplicationContract`, `getInputBox`,
    `getTournamentFactory`, `getDeploymentBlockNumber`,
    `getCurrentSealedEpoch`, `getLastFinalizedMachineMerkleRoot` and the
    `EpochSealed` event (`mod.rs:81-208`, `262-270`, `672-677`).
  - `IInputBox.getNumberOfInputs` and the `InputAdded` event (`mod.rs:666`,
    `567`).
  - Only the startup half (`AddressBook`) touches `getTournamentFactory`,
    `getLastFinalizedMachineMerkleRoot` and `getApplicationContract`.
- `lib.rs:4-6`: `blockchain_reader` is `pub` only because `AddressBook` is a
  `NodeConfig` field. That is a leak of startup into this module.

## Boundary verdict

The ingestion half (`mod.rs:287-836` plus `ingest.rs`) is a real boundary. It
is the node's only finality obligation: the input list behind the root claim.
It is the only writer of its tables. It is crash-consistent by one
transaction per tick, and it is the only place a silent lie (an omitted log)
is distrusted. Nothing it holds in memory matters.

The `AddressBook` half (`mod.rs:26-285`) is historical: deployment discovery
and seed selection run once at startup from `args.rs` and share no state with
the loop. The loop's stale-head and stale-finality pages are endpoint health,
not ingestion (Q5, under Candidate 6).

## Docs versus code

- `docs/node-architecture.md:217-219` says the stale-latest ERROR fires "on
  every tick". The code checks only on caught-up ticks, failed ticks included
  (`mod.rs:359`, `369`), so it is silent during catch-up chunks. Minor.
- `docs/node-architecture.md:544-546`: "a log missing from its tail surfaces
  only later... and then stops ingestion". This is accurate for inputs, but it
  omits that a dropped seal lets later chunks commit wrongly-epoched inputs
  first (`mod.rs:1519-1525`; Invariant 6).
- `docs/node-architecture.md:566-569`: pre-seed history is stored "since the
  node numbers inputs from the application's first". This matches the code,
  more precisely: the next index is `SELECT COUNT(*) FROM inputs`
  (`queries.rs:111-116`).
- `docs/epoch-lifecycle.md:20-23`: `EpochSealed` carries the lower bound. The
  reader ignores it (`mod.rs:534-550`). Lower == previous upper is a contract
  rule (`DaveConsensus.sol:270-271`), not re-checked.
- `lib.rs:4-6` vs `docs/node-architecture.md:15-23`: the docs name three
  workers, and the reader module also hosts startup deployment discovery and
  seeding. That concept has no home of its own.

## Defended mechanisms

- Totals shortcut (`mod.rs:431-443`, `490`, `501`). Premise: input count and
  sealed epoch number are monotone, so equal totals mean no new logs.
  - It buys a quiet tick with no `eth_getLogs` over any range, and it is the
    only tail check (Q2).
  - It costs two point reads per new finalized block.
  - Pinned at `mod.rs:1345-1421`.
- Chunking at 10,000 blocks (`mod.rs:295`, `445`). This bounds memory and
  restart loss on catch-up. Its cost is the tail stall (Q2), accepted because
  checking an intermediate end needs archive state (`mod.rs:449-451`).
- The eager split before the seal (`mod.rs:633-642`). Without it the runner
  would execute an input past the 2^24 span in an open epoch. The backward
  check (`mod.rs:603-617`) turns an uncapped consensus into a loud refusal.
  Recorded decision, not reopened (`docs/epoch-lifecycle.md:29-39`).
- Typed `LogCheck` and its remedy text (`mod.rs:343-349`, `689-727`). About 40
  lines. The remedy differs from a transient failure ("rebuild"), and a
  wrong-remedy page costs an operator hours.

## Candidate changes

1. Move `AddressBook`, `initial_watermark`, `seed_epoch` and `settled_epoch`
   (`mod.rs:26-285`) into a startup/deployment module, and make
   `blockchain_reader` crate-private.
   - Premise: only `args.rs:452-497` calls them.
   - Buys: about 260 lines off the reader; drops the `pub` reason at
     `lib.rs:4-6`; and `getTournamentFactory` and
     `getLastFinalizedMachineMerkleRoot` leave the reader.
   - Risk: none beyond churn of the test imports (`test_utils` users).
   - Reopen if: none.
   - Confidence: high.
2. Make numbering a pure function of the global index and the last sealed
   epoch row: for `i < B_last`, the sealed epoch; for `i >= B_last`, epoch
   `last + 1 + (i - B_last) / 2^24` at position `(i - B_last) % 2^24`. Take the
   next expected index from `last_input` plus the epoch bounds, not COUNT(*).
   - Premise (Q1): no in-memory state is carried today, but the walk threads
     three cursors (`mod.rs:590-599`, `773-775`) derived from COUNT(*) and the
     last row. The index and the bounds determine them.
   - Buys: a simpler `construct_input_ids`, no O(n) COUNT(*) per tick
     (`queries.rs:113`, called at `mod.rs:470` and `590`), and the
     precondition for 3 and 4.
   - Costs: rewriting tested code; the backward seal check must survive.
   - Could break: Invariants 1-3 if done carelessly.
   - Reopen if: 3 or 4 is wanted.
   - Confidence: medium.
3. Q6: do not store pre-seed history. Today nothing outside the reader reads
   `inputs` below the seed epoch. The runner reads only its boundary epoch
   (`advance.rs:157-189`), which starts at the seed (`open.rs:359`). The
   manager reads only the cursor's row and the last epoch row. The reader
   needs those rows solely for COUNT(*) (`mod.rs:470`, `590`) and the totals
   comparison (`mod.rs:433`, `738`).
   - Change: seed a base index, epoch k's `inputIndexLowerBound`, which
     `getCurrentSealedEpoch` already returns at the seed read (`mod.rs:182-191`;
     `DaveConsensus.sol:304-320`). Seed epoch k-1's row too, and drop events
     with index below the base.
   - Still costs the log scan from genesis, unless the start block is found by
     an indexed-topic query for that index. Lead, not verified: `InputAdded`'s
     `index` being indexed.
   - Requires 2.
   - Buys: disk proportional to the application's lifetime input bytes.
   - Reopen if: seeded deployments with large histories appear.
   - Confidence: low-medium.
4. Prune `inputs` below min(the completion cursor, the runner's boundary
   epoch).
   - Requires 2. COUNT(*) numbering breaks the moment a row goes.
   - Also requires changing the DELETE discipline test
     (`discipline.rs:46-53`).
   - Buys: the same disk as 3, for unseeded nodes.
   - Confidence: medium, once 2 lands.
5. Self-heal the catch-up tail stall by committing a chunk's watermark only to
   its last log's block minus one.
   - Not worth it. A chunk whose logs sit in its first block makes no
     progress. A provider that truncates a successful response is outside the
     trust model. The remedy (rebuild) is named in the page.
6. Move the stale-latest and stale-finality pages to the manager or to their
   own task.
   - Not worth it. The reader's loop is the node's light, steady poll. The
     manager's tick can block on Hero machine work
     (`docs/node-architecture.md:110-121`).
   - The finality page is ingestion's own concern. The latest page guards the
     Hero's clocks, so it is a guest here.
   - Keep it, but name the guest in the module doc.
   - Confidence: medium.
7. Check `inputIndexLowerBound == previous upper`, or the input payload
   against the InputBox's stored hash.
   - Not worth it. The first restates a contract rule
     (`DaveConsensus.sol:270`), and omission is already caught.
   - The second is a per-input RPC against a trusted-RPC lie (P2 scope,
     `docs/node-architecture.md:151-162`).
   - Not verified: whether the binding exposes an input-hash getter.

Q1 (numbering): see Owns, and Invariants 1-3. Q2: the totals check compares
the stored COUNT(*) and the MAX sealed epoch number with
`getNumberOfInputs(app)` and `getCurrentSealedEpoch().epochNumber` at `F`
(`mod.rs:664-684`, `736-761`).
- Skips: all log queries when both totals match (`mod.rs:433-442`), and each
  kind's query when its own total matches (`mod.rs:490`, `501`).
- The tail stall is still reachable as described. A catch-up chunk with
  `chunk_end < F` commits on contiguity alone (`mod.rs:452`, pinned at
  `1536-1543`).
- A truncated tail is then below the watermark forever. The next input fails
  `InputIndex`, the next seal fails `StoredEpochs`, or `F` fails `Head*`, on
  every retry.

Q4: P2 checks are `InputIndex`, `SealedBound`, `HeadInputs`,
`HeadSealedEpoch`, the stored continuity checks, and the block-number and sort
rules (`chain.rs:194-203`).
- Restating the contract: the 2^24 cap checks (`mod.rs:604-617`, `798-802`).
  They serve the node's coordinate requirement against uncapped deployments.
- Restating the contract: the u64 range errors (`mod.rs:535-545`), the
  epoch-0 start (`ingest.rs:112`) and `validate_next`.

Q7: a minimal specification for an independent epoch-replay tool:
- (a) Genesis = min(the application's and the consensus's
  `getDeploymentBlockNumber`), and only finalized blocks.
- (b) `InputAdded` from the InputBox with topic1 = app, and `EpochSealed` from
  the consensus, over inclusive ranges. Split failed ranges.
- (c) Order by (block, tx index, log index). Refuse logs without a block
  number.
- (d) The global index starts at 0. Each event must carry the next index.
- (e) Sealed epoch e covers `[upper(e-1), upper(e))`, with epoch 0 from 0;
  epochs are dense from 0 and may be empty.
- (f) Positions restart at 0 in each epoch. Refuse more than 2^24 per epoch.
- (g) An open epoch's inputs past 2^24 belong to the next epoch numbers in
  2^24 windows, and a later seal must match those windows.
- (h) At the final head, the totals must equal `getNumberOfInputs` and
  `getCurrentSealedEpoch` read there.
- The payload is the raw `input` bytes (`mod.rs:808`).

## Not verified

- Whether `InputAdded.index` is an indexed topic (the bindings are generated;
  `IInputBox.sol` is not in this worktree).
- An input-hash getter on IInputBox.
- The runtime cost of COUNT(*) at large row counts. No test pins the
  stale-head pages.
- `epoch_manager/recovery.rs` reads of `epochs` beyond those cited.
- `harness/` use of `test_utils`.
