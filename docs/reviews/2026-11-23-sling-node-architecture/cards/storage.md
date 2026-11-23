# Card: storage (SQLite schema, snapshot store, engine config row)

Scope (production lines, `#[cfg(test)]` modules excluded), under
`cartesi-rollups/node/src/`: `storage/open.rs` 570, `storage/advance.rs` ~641
(648 minus the test-only `begin_advances`, 258-264), `storage/snapshots.rs` 464,
`storage/queries.rs` ~259, `storage/dispute.rs` 188, `storage/mod.rs` 183,
`storage/ingest.rs` 129, `storage/sql/schema.sql` 102, `storage/sql/schema.rs` 85,
`storage/completion.rs` 55, `storage/error.rs` 39, `storage/convert.rs` 33,
`storage/sql/mod.rs` 12, `engine/config.rs` 126. Test-only: `storage/sql/discipline.rs`
95, `storage/sql/test_helper.rs` 106. About 2,890 production lines.
`storage/rollups_machine.rs` (597) is read only where cited.

## Possible correctness bug

None met. Two near misses, both reachable only through corruption or a
non-release emulator, recorded under Invariants 6 and Candidate 1.

## Owns

The data directory: `node.lock` (open.rs:40, 48-79), `db.sqlite3`
(open.rs:523-525), `snapshots/0x<hash>/` (snapshots.rs:461-463), the
`.work-<pid>-<seq>` staging namespace (snapshots.rs:141-149), the startup sweep
(snapshots.rs:167-188), the version stamps (schema.rs:16, 20), the pin
(engine/config.rs:64-81) and its startup comparison (open.rs:478-521).

### Schema map

Writers and readers below are production call sites. Threads: reader = the
blockchain-reader task (lib.rs:88-98), runner = the blocking machine-runner
thread (lib.rs:72-86), manager = the epoch-manager task (lib.rs:100-118), Hero =
runs inside the manager task, machine work via `block_in_place`
(hero/mod.rs:23-26), setup = `NodeConfig::setup_with` before workers start
(args.rs:469-500).

**node_metadata** (schema.sql:7-11): singleton `id = 0`, `store_format > 0`,
`commitment_semantics > 0`, WITHOUT ROWID. Class: write-once identity cell.
Writer: `schema::initialize` schema.rs:41-46 (setup), same transaction as the
whole DDL batch (schema.rs:39); no other table rows except the DDL's own seed
rows of `latest_processed` and `epoch_completion` (schema.sql:51-52, 59).
Reader: schema.rs:54-79 (setup), exit 40 on a missing row or either mismatch.
Invariant: the store is readable by this binary; enforced only at startup.
Crash: created atomically with the schema, so never a schema without a stamp
(a schema without stamp is refused, test schema.rs:179-184). Derivable: yes
(constants). Loss: exit 40, rebuild. Never deleted.

**settlement_info** (schema.sql:13-31): PK `epoch_number >= 0`; every blob
typed and length-checked (32, or 1888 = 59 x 32 siblings). Class: write-once
cell per epoch. Writer: `insert_settlement_in` advance.rs:576-627 via
`roll_epoch` advance.rs:511-551 (runner), in one transaction with the
`epoch_snapshot_info (e+1, 0)` row (advance.rs:525-539); equal replay absorbs,
disagreement panics (advance.rs:615-625); an invalid proof panics before insert
(advance.rs:581-587). Readers: `settlement_info` queries.rs:143-145 by the
manager (epoch_manager/mod.rs:204); the roll's conflict check
(advance.rs:616). Every read revalidates the proof and panics on failure
(queries.rs:199-233). Crash: never without its `(e+1, 0)` row, nor the reverse.
Derivable: from the epoch's window roots plus the final boundary snapshot, but
only the roll computes it and the roll runs only while the cursor ends the
sealed epoch (advance.rs:148-160); once the cursor moved on, loss = rebuild.
Never deleted.

**epochs** (schema.sql:33-38): PK `epoch_number >= 0`; no other CHECK;
`root_tournament` stored as hex TEXT (ingest.rs:123) and parsed back
(queries.rs:244-262). Class: append-only log, dense from 0. Writer:
`insert_epochs_in` ingest.rs:95-128 (reader), same transaction as watermark and
inputs (ingest.rs:27-32); density checked against `MAX(epoch_number)+1`
(ingest.rs:112-118, queries.rs:152-156). Readers: `last_sealed_epoch`
queries.rs:47-61 (reader blockchain_reader/mod.rs:473, 490, 498; manager
epoch_manager/mod.rs:194); `unfinished_epoch` queries.rs:33-45 (manager
epoch_manager/mod.rs:188); `epoch_is_sealed_in` advance.rs:135-144 (runner plan
and roll); `epoch_count_in` (ingest, `complete_epoch` completion.rs:29).
Derivable from chain (finalized logs). Loss: re-ingestion from the watermark is
impossible without also dropping inputs; rebuild. Never deleted.

**inputs** (schema.sql:40-45): PK `(epoch_number, input_index_in_epoch)`.
Class: append-only log. Writer: `insert_inputs_in` ingest.rs:57-93 (reader),
sequence by `InputId::validate_next` (mod.rs:147-167), typed error
`InconsistentInput`. Readers: `advance_plan` payloads advance.rs:185-224
(runner, asserts no hole); `input` queries.rs:63-87 (Hero: crossing
machine_stf.rs:722-727, dispute feeder machine_stf.rs:391-396, 541-546);
`input_count` queries.rs:120-129 (Hero machine_stf.rs:671, engine/dispute.rs:257);
`total_input_count`, `last_input` (reader blockchain_reader/mod.rs:470, 586,
590). Derivable from chain. Never deleted (no GC: `total_input_count` is
`COUNT(*)` over all epochs, queries.rs:111-116, so pruning would break input
numbering).

**latest_processed** (schema.sql:47-52): singleton `id = 1`, `block >= 0`,
seeded `(1, 0)` by the DDL. Class: monotonic watermark (`MAX` upsert,
ingest.rs:38-47). Writers: reader tick (ingest.rs:28); seed transaction
(open.rs:358). Reader: blockchain_reader/mod.rs:420. Derivable: it is the cut
of the two logs; loss is meaningful only with them. Never deleted.

**epoch_completion** (schema.sql:54-59): singleton, `next_epoch` integer
`>= 0`, seeded 0. Class: monotonic cursor (+1 only). Writers:
`complete_epoch` completion.rs:20-41 (manager, epoch_manager/mod.rs:149, after
dropping the Hero at :148), checks order and that the epoch was ingested;
`seed_cursor_in` completion.rs:47-54 (seed transaction, open.rs:360). Readers:
`unfinished_epoch_number_in` queries.rs:235-242 via the manager and via the
runner's GC bound `collectable_epoch_in` advance.rs:631-635. Invariant: every
epoch at or above it keeps its boundary rows. Not derivable cheaply (needs the
finalized settlement and bond scan). Loss (reset below collected epochs): the
manager would build a Hero whose `(e, 0)` row was collected and panic at
hero/actor.rs:144-146. Never deleted.

**epoch_snapshot_info** (schema.sql:61-71): PK `(epoch_number, input_number)`,
`state_hash` 32-byte blob; paths derived, never stored. Class: write-once cells,
pruned by GC. Writers: seed (open.rs:359, with watermark, cursor and pin);
`commit_advances` advance.rs:468-471 (runner, with that batch's window roots in
`sling_nodes`); `roll_epoch` advance.rs:532 (runner, with `settlement_info`);
`publish_crossing` advance.rs:499-503 -> `insert_boundary` snapshots.rs:195-202
(Hero, alone). All through `insert_snapshot_in` snapshots.rs:388-418 (equal
absorbs, unequal panics). Deleter: `release_boundaries_in` snapshots.rs:429-444
(runner GC, with the `sling_nodes` prune, advance.rs:640-647). Readers: see
section 3 below. Crash: a row never names an unpublished directory (filesystem
first); a directory may lack a row. Derivable by re-execution; loss of the
newest row costs one batch replay (the previous row becomes the cursor and
replays absorb), loss of `(e, 0)` for the manager's epoch panics the Hero
(hero/actor.rs:146).

**sling_config** (schema.sql:82-93): `id = 0` PK, nine NOT NULL columns, no
length checks on the blobs. Class: write-once identity. Writer: `config::pin`
engine/config.rs:64-81 (setup, last statement of the seed transaction,
open.rs:361); a second pin fails on the PK. Readers: `config::stored`
engine/config.rs:84-125 at startup (`check_pinned` open.rs:311-313) and through
`Storage::sling_config` dispute.rs:22-26 by reader (blockchain_reader/mod.rs:325,
chain id), runner (machine_runner/mod.rs:104; advance.rs:284, 561, stride),
Hero (hero/actor.rs:150; machine_stf.rs:669; engine/dispute.rs:231). Its row's
existence is also the "seeded" marker (`is_seeded` open.rs:249-280). Derivable
from flags, chain and binary. Never deleted.

**sling_nodes** (schema.sql:95-102): PK `(epoch, log2_stride, height, shift)`,
`shift` a 32-byte big-endian blob (dispute.rs:186-188), so blob order is
numeric order for `shift < ?`. No CHECKs. Class: write-once cells, pruned by
GC; two populations (section 4). Writers: `commit_advances` advance.rs:453-471
(runner); `insert_quartet_nodes` dispute.rs:50-52 from engine/cache.rs:87 and
:140 (Hero). Both via `insert_quartet_nodes_in` dispute.rs:144-184 (equal
absorbs, unequal panics). Deleter: advance.rs:642-645 (runner GC). Readers:
`quartet_node` dispute.rs:28-44 (Hero, engine/cache.rs:38, :119;
engine/dispute.rs:448-449); `window_root_count` dispute.rs:62-81 (Hero,
engine/dispute.rs:258); `window_root_range` dispute.rs:89-138 (runner
advance.rs:563; Hero engine/dispute.rs:386). Loss: cache rows cost machine time
on the dispute clock; window roots are not recomputable (see 4) = rebuild.

### 1. Versioning fingerprints

| Fingerprint | Set by | Compared at | Exit |
|---|---|---|---|
| `STORE_FORMAT` | hand bump, schema.rs:16 | schema.rs:66-72 | 40 |
| `COMMITMENT_SEMANTICS` | hand bump, schema.rs:20 | schema.rs:73-79 | 40 |
| app, chain id | flags, pinned at seed | open.rs:484-500 | 30 |
| initial hash (`template_hash`) | chain, args.rs:507 | open.rs:501-511 | 30 |
| consensus, emulator, geometry, structure | chain, linked lib, constant | open.rs:512-519 (whole-row `==`) | 40 |

The schema pin test (schema.rs:110-123) hashes `schema.sql` and forces a
decision on `STORE_FORMAT` at every edit; nothing forces a decision on
`COMMITMENT_SEMANTICS`, which is on the author's discipline (schema.rs:17-19).
Overlaps: `structure` (three spans, engine/config.rs:68-71) is a code constant
(`Structure::PRODUCTION`, engine/config.rs:51); any change to it changes leaf
coordinates and so already demands a `COMMITMENT_SEMANTICS` bump: two guards on
one thing, harmless. Geometry is a function of the consensus's immutable
factory (cartesi-rollups/contracts/src/DaveConsensus.sol:48) unless the
factory's level table can change; the pin then guards the trusted "stable
parameters provider" (docs/node-architecture.md:196-198), not drift the
consensus pin misses (lead: I did not read the factory).

Emulator version: `format_emulator_version(Machine::version())`
(engine/config.rs:56) prints `major.minor.patch` from `cm_get_version()`
(machine/rust-bindings/cartesi-machine/src/lib.rs:30-35, machine.rs:109-111),
which returns `CM_VERSION_NUM` (emulator `src/cm.cpp:162-164` at the pinned
commit). No pre-release label reaches the pin at all, so it cannot tell
v0.23.0-test2 from -test3 from the v0.23.0 release, worse than the CLI case
docs/test-harness.md:107-113 records. What actually guards stored material
against a same-number emulator change: MARCHID and pristine uarch hash checked
against the deployed step at every start (args.rs:65-86, 140-158, exit 30, not
pinned); every boundary load re-verifies its root against its row
(snapshots.rs:79-98, machine_stf.rs:784-798, panic 101); an archive-format
change is refused by the emulator loader (node README.md:309-311); and the
quartet collision tripwire (dispute.rs:176-180) where a recomputation overlaps
a stored row. Uncovered: an interpreter change that keeps MARCHID, uarch and
the hash function. Its stored window roots and settlements would be wrong
silently until a recomputation overlaps them. Production runs releases, so the
exposure is test tags. See Candidate 1.

### 2. SQLite versus the snapshot directories

Order: stage a clone in `.work-*` (snapshots.rs:141-149), verify its root
against the CAS key (snapshots.rs:109-113), sync and rename without replacement
(`Volatile::persist`, machine/rust-bindings/cartesi-machine/src/stored.rs:82-88),
then commit the row in a later transaction (advance.rs:451-471, 501-502,
open.rs:355-363). An existing destination is adopted after a `sync`, without
rehashing (snapshots.rs:119-126, 131). GC is the mirror: delete rows and
compute orphans in one transaction (snapshots.rs:429-444), remove directories
after commit (advance.rs:250-255, snapshots.rs:450-458), with
`synchronous=FULL` so a power loss cannot undo the commit while the removals
persist (open.rs:32-38). Startup sweeps `.work-*` and `.part-*` under the lock,
before seeding and before the pin check (open.rs:306-313). Filesystem states a
row may assume: its directory exists and is a complete, synced, root-verified,
closed stored machine. Only the runner's cursor demands it (panic,
snapshots.rs:59-75); positioning skips a vanished directory
(snapshots.rs:242-247) but panics on a root mismatch (machine_stf.rs:784-798).
Orphans: a crash after rename (re-adopted by the replay) or after a GC commit
(never re-adopted, disk only, snapshots.rs:446-449). A GC crash mid
`remove_dir_all` leaves a torn orphan; adoption would accept it, but the
non-recurrence argument (docs/node-architecture.md:443-447) says its hash never
returns. That argument carries crash safety too, not only concurrency; the doc
states it only for concurrency.

### 3. The uses of `epoch_snapshot_info`

1. Runner's durable cursor: newest row by `(epoch DESC, input DESC)`
   (`latest_boundary_in` snapshots.rs:334-358), read by `advance_plan`
   advance.rs:169, the roll guard advance.rs:149, `latest_snapshot`
   snapshots.rs:274-295, GC bound advance.rs:633, and the manager's wait log
   (`next_input_id` queries.rs:133-141, epoch_manager/mod.rs:268-271).
2. Replay floors: `nearest_boundary_at_or_before` snapshots.rs:214-254 (Hero,
   machine_stf.rs:765-767), then `snapshot_hash` for the root check
   (machine_stf.rs:784-788).
3. Epoch start state and level-0 implicit hash: row `(e, 0)`
   (hero/actor.rs:142-146).
4. Final boundary as the frontier's padding: `(e, recorded)`
   (engine/dispute.rs:272-279).
5. Crossing publications: `(e, to)` by the Hero (advance.rs:499-503).
6. GC orphan accounting (snapshots.rs:431-438).
7. The e2e harness's `(e, 0)` path (Outside readers).

What keeps them apart: a Hero for epoch `e` exists only once
`settlement_info(e)` exists (epoch_manager/mod.rs:204), which commits with
`(e+1, 0)` (advance.rs:532-538), so crossing rows of `e` never sort newest;
equal rows absorb (snapshots.rs:408-416), so a crossing to `inputs` coincides
harmlessly with the runner's final row; GC takes only epochs below both the
completion cursor and the runner's epoch (advance.rs:629-635), and the manager
drops the Hero before advancing the cursor (epoch_manager/mod.rs:147-149).

### 4. The two populations of `sling_nodes`

Window roots: coordinate `(e, root stride, window height, shift = input)`
(rollups_machine.rs:213-232), written by the runner with their boundary
(advance.rs:453-471); they are the only level-0 artifact (advance.rs:84-91) and
the settlement root is folded from them (advance.rs:560-571). Cache rows: every
other coordinate, written lazily by the Hero (engine/cache.rs:85-87, 139-140),
including padding-window roots at the same `(stride, height)` with
`shift >= inputs`. Readers tell them apart only by the prefix rule `shift <
input count` (dispute.rs:54-81, 83-138; engine/dispute.rs:241-270), a rule that
once "bricked reconstruction" when it was missing (engine/dispute.rs:245-246).
The two populations deliberately overlap: when the Hero recomputes a window-root
parent, its fanout insert hits the runner's row and the equal-or-panic check
cross-verifies the runner (engine/dispute.rs:451-455, dispute.rs:160-180). Not
a cache: with no window-root rows the source serves only single-input quartets
(engine/dispute.rs:247-252), and roll refuses holes (dispute.rs:119-125). See
Candidate 3.

### 5. Discipline tests

`mutation_taxonomy_holds_at_source_level` (discipline.rs:11-55) counts the
substrings `UPDATE` and `DELETE FROM` per file. It scans only the top level of
`src/storage` (`read_dir`, discipline.rs:18), so it misses `sql/`, and it misses
`engine/config.rs`, the `sling_config` writer. It does not see `REPLACE` or
`INSERT OR REPLACE`, and it counts comments. `schema_file_is_the_only_ddl_source`
(discipline.rs:57-95) recurses but also stops at `src/storage`. A grep is the
right weight for a module whose writers are 4 small files: it fails loudly and
costs nothing. It pins the file and the count, not the table or the class. A
SQLite trigger would enforce at the engine (Candidate 5).

### 6. Connections

Each `Storage` owns one connection (open.rs:81-85). Production opens: the setup
probe (open.rs:259-263, short-lived, before the lock, no WAL pragma) and the
initialize handle (open.rs:299, dropped at the end of `setup_with`); reader,
runner, and manager each one (lib.rs:76, 92, 105 via args.rs:385-387); the
Hero's `DisputeSource` one (epoch_manager/mod.rs:569); its `Positioner` one
(machine_stf.rs:678); and one more per ruler it positions
(machine_stf.rs:813-818). About six at steady state during a dispute. Pragmas:
WAL, `synchronous=FULL`, busy timeout 10 s (open.rs:463-468). Reads are Deferred
(open.rs:430-437), writes Immediate (open.rs:444-451); several point reads run
in autocommit on the raw connection (dispute.rs:22-44, 62-81). No transaction
spans machine work or an RPC: roll loads and proves before its write
(advance.rs:512-539), commits publish before their write (advance.rs:451, 501),
GC reads, writes, then touches the filesystem (advance.rs:250-255), the reader
does RPC then one write (blockchain_reader/mod.rs:478-494).

### 7. Outside readers

- test/e2e/rollups/dave/node.lua:161 opens `db.sqlite3` with `sqlite3 -readonly`;
  :162-163 `epochs`; :184-185 `settlement_info.computation_hash`; :228-230
  `epoch_snapshot_info` row `(e, 0)`; :244 builds `snapshots/0x<hash>`;
  :258-260 `inputs`. Used by test/e2e/rollups/test_env.lua:101, 202, 212-217,
  which loads the node's snapshot directory with the Lua machine (:213).
- cartesi-rollups/node/tests/engine_machine.rs:1509-1515 lists `snapshots/`
  for staging names; :1529 uses `epoch_snapshots`, whose only caller this is.
- The operator procedure: cartesi-rollups/node/README.md:291-301 tells an
  operator to seed from another node's `snapshots/0x<hash>` directory.
- No script or justfile reads the tables (git grep of `*.sh`, justfiles, `*.lua`).

## Takes

Inputs and epochs from the reader, trusted as finalized and complete; the
writer checks only density (ingest.rs:49-128). Machine states and runs from the
runner and the Hero; the writer trusts the caller's hash only after
re-verifying the staged root (snapshots.rs:109-113) and checks that the final
run equals the boundary (advance.rs:334-338, 398-402). The engine config from
setup (chain reads and the linked library). Completion from the manager,
trusted to be after finalized settlement and bond recovery (completion.rs:14-19).

## Gives

A coherent runner plan from one snapshot (advance.rs:32-46, 167-235); a verified
cursor machine (snapshots.rs:274-295); a settlement whose proof was revalidated
on read (queries.rs:199-233); the pinned config; window roots strictly by
prefix; replay floors best-effort. Promise: no row names a missing or
unverified machine except through external mutation.

## Invariants

1. Every row names a directory that was root-verified and synced before the row
   committed. Enforced by order (advance.rs:451-471, snapshots.rs:108-134). Broken:
   a runner panic (snapshots.rs:59-75) or a positioning panic.
2. GC never removes a directory a surviving row names: same-transaction orphan
   query (snapshots.rs:431-442), removal after commit, FULL sync (open.rs:38).
3. GC never touches the manager's epoch or the runner's newest:
   advance.rs:629-635; test completion.rs:107-177.
4. Write-once cells panic on disagreement: snapshots.rs:408-416,
   advance.rs:615-625, dispute.rs:160-181. An `Err` would loop forever in the
   tick retry (dispute.rs:172-175).
5. Logs are dense: ingest.rs:49-55, 112-118; re-asserted by the runner
   (advance.rs:200-215).
6. `settlement_info(e)` exists iff `(e+1, 0)` exists (one transaction,
   advance.rs:525-539). If corruption deletes the settlement alone, the manager
   waits silently at DEBUG (epoch_manager/mod.rs:268-289), no page: corruption
   only, not chain-reachable.
7. The pinned row equals the running configuration: open.rs:478-521, exit 30 or 40.
8. One process per directory: `StateDirLock` (open.rs:54-78); refuses an
   unlockable filesystem.

## Concurrency and crash consistency

Threads: reader, runner, manager+Hero, each on its own connection; SQLite
serializes writers. Kill -9 points: inside seed after the clone is published
(orphan, re-adopted on the next seed: open.rs:338-343; `is_seeded` stays false
until the pin commits, open.rs:244-248); inside a batch (`.work-*` swept at
start, snapshots.rs:162-188; replay one batch); after publish before the row
(orphan adopted on replay, snapshots.rs:124-126); inside roll (no filesystem
effect; one transaction); after GC commit (orphan forever, disk only);
mid-crossing (staging swept, publication re-adopted). Process memory only:
`AdvanceBatch` (advance.rs:66-82, a batch replay), the frontier's memoized top
tree (engine/dispute.rs:381-399, rebuilt from rows), the `SEQ` counter
(snapshots.rs:142).

## What it knows about its neighbours

- Engine geometry: `window_root_quartet` and `window_height`
  (rollups_machine.rs:213-232), `fold_runs` and `level0_tree`
  (advance.rs:96-108, 569). Needed: the settlement root must be the root the
  Hero defends from the same rows (advance.rs:553-559).
- Runner and crossing clone mechanics live in storage (`rotate_*`,
  advance.rs:353-436, `begin_crossing` 487-494): storage owns the clone chain
  because it owns the staging namespace. Needed, though `AdvanceBatch` is used
  by the Hero for a crossing with an empty record list (advance.rs:500).
- Machine semantics: `Template::inspect` checks uarch, hash function and file
  modes (open.rs:96-172). That is seed-image validation, not storage. A leak,
  but a small one.
- `sling_config` lives in `engine/config.rs` but is storage identity.

## Boundary verdict

Real. It is the crash-consistency boundary: one durable surface with
filesystem-first publication, same-transaction GC accounting and write-once
tripwires. It is also the concurrency boundary between three tasks that share
no memory. The role split into files (ingest, advance, dispute, completion) is
a convention, not a type boundary: any `Storage` holder can call any writer.
That is acceptable at this size.

## Docs versus code

- docs/node-architecture.md:469-472 says the Hero "opens its own connection".
  Code: two long-lived ones plus one per ruler (epoch_manager/mod.rs:569,
  machine_stf.rs:678, 813-818).
- docs/node-architecture.md:469-471 calls the dispute tables "restartable
  state"; `sling_nodes` also holds the window roots, which are not restartable
  (advance.rs:84-91, dispute.rs:115-125). :476-478 half-corrects this.
- docs/node-architecture.md:424 "`sql/discipline.rs` pins where in-place writes
  and deletes may appear": only in top-level `src/storage` files
  (discipline.rs:18); `engine/config.rs` is outside its view.
- docs/node-architecture.md:290 names `dispute.rs` the "player" role; the
  module says hero (mod.rs:11, dispute.rs:4).
- `template_hash` (schema.sql:90, engine/config.rs:31-33) is the deployment's
  initial hash, not the seeding image, which may be a later epoch's state
  (open.rs:233-241). The name misleads.
- open.rs:283-285 "a wrong flag leaves it untouched": schema check and staging
  sweep run before `check_pinned` (open.rs:300, 309, 313). So an older store
  with a wrong flag exits 40, not 30, and staging leftovers are swept. Harmless.
- The non-recurrence argument (docs/node-architecture.md:443-447) is
  load-bearing for crash safety too (a torn GC orphan is never adopted), and
  says so only for concurrency.

## Defended mechanisms

- Filesystem-first CAS with adopt-without-rehash: makes replay idempotent and
  publication a rename; the price is relying on the lock and non-recurrence
  (docs/node-architecture.md:377-382).
- `synchronous=FULL`: the commit gates an external deletion (open.rs:32-38).
- Write-once panics instead of errors: the tick loops retry errors forever
  (dispute.rs:172-175, advance.rs:618-619).
- The cursor-dir assert before readiness (advance.rs:236-243): an idle open
  tail cannot hide a dangling cursor.
- Two stamps plus the schema pin: cheap, and they make every schema edit
  decide (schema.rs:12-20, 110-123).
- One table for both `sling_nodes` populations buys the cross-check in
  section 4. Kept for now, see Candidate 3.

## Candidate changes

1. Pin an emulator identity that sees pre-releases (a version label or the
   library's build digest) instead of `major.minor.patch`. Premises: the pin
   promises "stored machines and commitments are this emulator's"; the number
   cannot tell a test tag from its release (section 1). Buys: exit 40 instead of
   a 101 loop or silent stale window roots across test-tag swaps. Costs: the
   bindings must expose the label (not checked: no `VERSION_LABEL` in
   machine/rust-bindings); a STORE_FORMAT bump. Reopen if tags stop being run on
   persistent directories. Confidence: medium.
2. Drop the `.part-*` arm of the sweep (snapshots.rs:162-164, 177). Premise: the
   `.part-` producer was removed (2026-10-19, "delete the dispute write-back's
   boundary store") before `STORE_FORMAT = 2` appeared (the commit moving to
   v0.23.0-test3). Older stores exit 40 at schema.rs:66-72, before the
   sweep (open.rs:300 vs 309). Buys a concept and a test fixture
   (open.rs:839). Risk: none if the history premise holds (verify that no format-2
   store predates the removal). Confidence: medium.
3. Split window roots out of `sling_nodes` into `window_roots(epoch, window,
   hash)`. Premises: two durability classes share one table and the prefix rule
   is a trap already hit once (engine/dispute.rs:245-246). Buys: removes the
   prefix rule and the stride and height columns, and makes "cache" true of
   `sling_nodes`. Costs: STORE_FORMAT bump. The Hero's recomputation of a
   window-root parent would need an explicit cross-check against the new table
   to keep the tripwire (dispute.rs:160-180). Invariant at risk: settlement root
   equals the defended root (advance.rs:553-559). Confidence: low to medium.
   Worth discussing, not urgent.
4. Remove or gate test-only public API: `epoch_snapshots` (snapshots.rs:300,
   only tests/engine_machine.rs:1529), `inputs` (queries.rs:89, harness only),
   `snapshot_dir` (snapshots.rs:257, tests only). About 60 lines. Integration
   tests need `pub`, so it is not worth it unless the test moves in-crate.
   Confidence: high that they are test-only.
5. Enforce the mutation classes with SQLite `BEFORE UPDATE`/`BEFORE DELETE`
   triggers. Not worth it: GC deletes would need trigger carve-outs, plus a
   format bump. External mutation is already declared unsupported
   (docs/node-architecture.md:382).
6. Page (WARN to ERROR) when the manager's epoch has no settlement and the
   runner's cursor is past it (epoch_manager/mod.rs:282-288). Corruption-only;
   one branch. Confidence: medium that it is worth a line.
7. Pin MARCHID and the pristine uarch hash in `sling_config`. Not worth it: the
   startup chain check already refuses both against the pinned consensus's step
   (args.rs:65-86, 140-158).
8. Prune `inputs` and `settlement_info` of collected epochs. Not worth it:
   `total_input_count` numbers inputs from `COUNT(*)` (queries.rs:111-116), and
   on-chain gas pays for the input bytes.

## Not verified

The tournament factory's mutability (whether geometry can drift under a fixed
consensus); `cm_rename_stored`'s parent-directory fsync; whether the e2e
harness's `(e, 0)` read (node.lua:228-244) can race the runner GC of a completed
epoch (it retries, test_env.lua:212); the Hero cache insert sizes against the
10 s busy timeout under load; the test modules' own SQL; `rollups_machine.rs`
beyond the cited lines.
