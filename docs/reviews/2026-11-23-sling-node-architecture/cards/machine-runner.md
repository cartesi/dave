# Card: machine runner and the storage it drives

Scope: `cartesi-rollups/node/src/machine_runner/mod.rs` (284 production
lines), `storage/advance.rs` (648), `storage/snapshots.rs` (464),
`storage/rollups_machine.rs` (370),
`machine/rust-bindings/cartesi-machine/src/stored.rs` (154). Paths without a
prefix are under `cartesi-rollups/node/src/`; bare `mod.rs` is
`machine_runner/mod.rs`; `machine.rs` is the bindings' file.

## Possible correctness bug

None met. Leads: (a) a crash between the batch commit (`mod.rs:262`) and the
terminal page (`mod.rs:264`) loses the page for good; staging still pages the
held epoch (`docs/node-architecture.md:144-147`). (b) Storage refuses no input
appended to a sealed epoch (`storage/ingest.rs:49-93`); the roll's guard
(`storage/advance.rs:148-160`) is the backstop (reader guard not read).

## Owns

- The durable cursor, the newest `epoch_snapshot_info` row
  (`storage/snapshots.rs:334-358`, checked at `54-98`); the clone chain
  (`snapshots.rs:108-149`, `advance.rs:353-381`, `416-436`), shared with
  crossings; one commit per gap (`mod.rs:13-17`, `advance.rs:447-472`).
- The roll and its computation hash (`advance.rs:511-571`); GC
  (`advance.rs:250-256`, `631-647`, `snapshots.rs:429-458`); the staging
  sweep (`snapshots.rs:167-188`, at `storage/open.rs:309`).
- Policies: the 1 GiB free-space floor (`mod.rs:70-94`), the terminal-input
  page (`mod.rs:195`, `244-246`, `263-270`), the paging clock (`mod.rs:125-135`).

## Takes

- Inputs and seals from the reader in one Deferred transaction
  (`advance.rs:167-235`, `open.rs:430-437`); contiguity asserted
  (`advance.rs:200-215`); a sealed epoch's inputs trusted frozen (re-checked
  only at the roll, `advance.rs:154-158`).
- The completion cursor (`advance.rs:632`, `queries.rs:235-242`), trusted
  monotonic; geometry from `sling_config` (`mod.rs:104-111`, `advance.rs:284`).
- Stored machines: the cursor's root is verified on every load
  (`advance.rs:312`, `snapshots.rs:287`) and every publication
  (`snapshots.rs:109-113`); an existing CAS directory is adopted by name
  (`snapshots.rs:115-126`), argued at `docs/node-architecture.md:377-382`.
- Engine: `MachineStf`, `Ruler`, `fold_runs`, `level0_tree` (`mod.rs:216-241`,
  `advance.rs:96-108`, `569`); tiling violations panic (`advance.rs:93-95`).

## Gives

- To the manager/Hero: `settlement_info(e)` with a validated proof, atomic
  with `(e+1, 0)` (`advance.rs:525-539`, `576-627`); its computation hash is
  `level0_tree` over the persisted window roots, the rows the dispute facade
  serves (`advance.rs:553-571`).
- To dispute positioning: a boundary row per gap (`advance.rs:469`),
  window-root quartet rows (`advance.rs:453-470`,
  `rollups_machine.rs:221-232`), and the rotation verbs with
  `begin_crossing`/`publish_crossing` (`advance.rs:483-503`).
- To operators: ms per input per batch (`mod.rs:271-280`), free space at a
  roll (`advance.rs:541-548`).

## Invariants

1. The cursor row's directory exists and hashes to the row: `snapshots.rs:59-98`,
   called at `advance.rs:239`, `283`, `291`, `308`, `312`, `snapshots.rs:277`,
   `283`, `287`. Else the runner advances from a state no row defends.
2. A batch starts at the cursor and stays contiguous: `mod.rs:28-42`,
   `205-209`; `advance.rs:171-174`, `200-215`, `361-365`, `423-427`.
3. A window's final run equals the recorded boundary: accepted
   `advance.rs:333-338`, rejected `advance.rs:398-402`. Else window roots and
   boundaries disagree: a wrong commitment.
4. Revert checkpoint hashes to the revert root (`machine_stf.rs:319-324`);
   CAS key equals the staged root before rename (`snapshots.rs:109-113`).
5. Filesystem first: publish (`advance.rs:451`, `501`) before the row
   (`advance.rs:468-471`, `502`). Else a row names an undurable machine.
6. Write-once cells panic on disagreement (`snapshots.rs:388-418`,
   `advance.rs:574-627`); roll readiness is checked in the settlement
   transaction (`advance.rs:148-160`, `526-531`).
7. No directory mapped shared is cloned, loaded or synced, by type:
   `Volatile::open` moves it into `Machine.home` (`stored.rs:72-77`,
   `machine.rs:200-207`), only `close` returns it (`machine.rs:240-244`).
8. GC only below both cursors, directories after commit (`advance.rs:629-635`,
   `252-253`); only GC deletes rows (`storage/sql/discipline.rs:46-54`); one
   process per directory (`open.rs:42-79`); FULL sync (`open.rs:32-38`).

## Concurrency and crash consistency

The runner is one blocking task with its own connection (`lib.rs:72-86`).
Crossings run in the manager's task with another connection
(`machine_stf.rs:676-678`) and share the CAS store, the `.work-` namespace
(one process-wide counter, `snapshots.rs:142-147`) and `epoch_snapshot_info`.
SQLite WAL with Immediate writes arbitrates (`open.rs:439-451`).

Q2, a kill -9 at each step of a batch:
- Mid-input or between inputs: SQLite unchanged; only `.work-` directories
  (the shared working clone, possibly torn, and transient checkpoints).
  Restart sweeps them (`open.rs:306-309`, `snapshots.rs:167-188`) and replays
  at most one gap from the batch's durable base. Same after `drop(machine)`
  (`mod.rs:261`).
- In `publish_staged` after `sync_stored`, before `rename_stored`
  (`stored.rs:82-84`): the synced directory still has its `.work-` name; swept.
- After the rename (durable with its parent entry, `machine.rs:268-271`),
  before the SQLite commit: a complete CAS directory without a row. The
  deterministic replay reaches the same hash and adopts it with a fresh sync
  (`snapshots.rs:115-126`).
- After the commit: boundary and window roots durable under FULL. Lost: the
  terminal page (lead a) and the paging clock.
- Roll: one transaction (`advance.rs:525-539`). In memory only: the batch's
  records and transient checkpoints (one gap of replay) and `failing`.

Q3, why a dispute's row can never be the newest. A Hero exists only for the
completion cursor's epoch (`epoch_manager/mod.rs:188`) and only once
`settlement_info(e)` exists (`epoch_manager/mod.rs:204-205`, built at
`570-577`; source at `hero/actor.rs:152`). The positioner's epoch is that
epoch (`machine_stf.rs:661-679`), its targets at most the input count
(`machine_stf.rs:799`). `settlement_info(e)` commits only with `(e+1, 0)`
(`advance.rs:532-538`), so every crossing row `(e, k)` sorts below it in
`latest_boundary_in` (`snapshots.rs:338-342`). Docs:
`docs/node-architecture.md:437-442`; comment `advance.rs:496-498`. Nothing
enforces it at the write (`advance.rs:499-503`, `snapshots.rs:195-202` never
compare with the cursor): an ordering by data dependency between manager and
runner. If broken, the runner would resume from a dispute boundary and skip
inputs; the root assert would pass, since the row names a true state.

Q1, per-input emulator calls (stride 2^38 takes the coarse loop,
`ruler.rs:165-168`). Batch start, once: clone of the durable base
(`advance.rs:286`), shared load (`advance.rs:305`, `rollups_machine.rs:274`),
root hash (`advance.rs:312`).

(a) Accepted input:
1. take the shared machine (`mod.rs:221`), wrap with no fs effect
   (`machine_stf.rs:217-239`), register reads (`mod.rs:227`, `230`).
2. feed: root hash (`machine_stf.rs:360`), `send_cmio_response` (`436`).
3. `machine.run` (`machine_stf.rs:464`); `restore_rejected` returns false
   (`machine_stf.rs:476`, `305-307`).
4. one root hash per emitted chunk holding a sample (`ruler.rs:447-448`,
   `505-513`) plus the idle tail (`ruler.rs:424-432`): two for a fast yield.
5. register reads (`mod.rs:244`); root hash (`advance.rs:333`).
6. checked close (`cm_destroy`) returns the clone (`advance.rs:366-369`,
   `machine.rs:240-244`); 7. clone into a new `.work-` (`advance.rs:370`,
   `snapshots.rs:141-148`); 8. shared load (`advance.rs:371-373`).
9. the old checkpoint, if transient, is removed by its drop
   (`advance.rs:377`, `stored.rs:105-117`); the durable base never is.
Count: 1 load, 1 clone, 1 close, about 4 root hashes, 1 removal (0 for the
batch's first accepted input).

(b) Rejected input:
1-2. as above.
3. `machine.run` hits the RX_REJECTED yield; `restore_rejected`
   (`machine_stf.rs:476`) loads the batch checkpoint privately
   (`machine_stf.rs:314`); the assignment drops the shared machine
   (unchecked `cm_delete`, `machine.rs:49-56`) and its home, removing the
   poisoned clone (`machine.rs:43-46`, `stored.rs:105-117`); root hash on the
   private machine (`machine_stf.rs:320`).
4. chunk and idle-tail hashes, on the private machine.
5. `record_reverted` compares runs, no hash (`advance.rs:398-402`).
6. `rotate_reverted` destroys the private machine, `close` returns `None`
   (`advance.rs:429`, `rollups_machine.rs:289-293`).
7. clone of the checkpoint (`advance.rs:430`); 8. shared load (`431-433`).
Count: 2 loads (private, shared), 1 clone, 2 destroys (one unchecked), about
4 root hashes, 1 removal. Confirmed: two loads per rejected input. In Advance
mode the private load serves the revert-root tripwire
(`machine_stf.rs:316-324`), the post-revert hashes for the rest of the
window that `record_reverted` checks against the boundary
(`advance.rs:398-402`), and the yield/terminal reads (`ruler.rs:418-432`,
`mod.rs:244`). Its machine is never run: `rotate_reverted` discards it.

Batch end: `drop(machine)` removes the unused last working clone
(`mod.rs:261`); `publish_staged` loads privately and hashes
(`snapshots.rs:109`), syncs and renames (`stored.rs:82-88`), skipped when
every input rejected (`advance.rs:476-481`). Roll: one private load and root
assert (`snapshots.rs:278-293`), proof capture (`rollups_machine.rs:350-369`).

Q4, GC runs at every `advance_plan` (`advance.rs:244`): every tick, idle or
not, and between batches. It deletes `epoch_snapshot_info` and `sling_nodes`
rows of epochs up to `min(next_epoch, cursor_epoch) - 1`
(`advance.rs:631-647`, `snapshots.rs:429-444`), then directories no kept row
names (EXCEPT keeps a state shared with a later epoch, `snapshots.rs:433-435`).
Never deleted: `inputs`, `epochs`, `settlement_info` (`discipline.rs:46-54`).
Orphans: a crash between GC commit and removal, or a failed removal
(`snapshots.rs:450-457`), stays until rebuild; a runner post-rename crash is
re-adopted by replay; a crossing's post-rename crash before `insert_boundary`
(`advance.rs:501-502`) is re-adopted only by an identical crossing, else
never removed, since GC removes only hashes found in rows; `.work-` leftovers
go at the next start.

Q5, the roll (`advance.rs:511-551`) reads the cursor machine
(`snapshots.rs:274-295`), captures and validates the proof
(`rollups_machine.rs:350-369`), folds window roots (`advance.rs:560-571`);
then one transaction re-reads the cursor, asserts sealed and boundary equal
to input count (`advance.rs:148-160`) and unchanged (`527-531`), inserts
`(e+1, 0)` and the settlement, re-validating the proof (`581-587`).
Duplicates: sealed-and-drained is decided by the plan (`advance.rs:175-183`,
`mod.rs:44-47`) and re-asserted at `advance.rs:150-158`; the cursor read by
`latest_snapshot` is re-read in the transaction; the proof is validated at
capture and at insert.

## What it knows about its neighbours

- Engine geometry and `Ruler` (`mod.rs:216-241`), the dispute cache's
  quartet rows and `level0_tree` (`advance.rs:470`, `569`;
  `rollups_machine.rs:221-232`): needed, so the settled root is the defended
  root (`advance.rs:553-559`).
- Consensus: "an epoch seals only once its predecessor is accepted"
  (`advance.rs:41-42`, `176-177`), used only by the floor (`mod.rs:159-161`).
  A small leak of chain semantics into planning.
- The completion cursor (`advance.rs:632`): needed for GC safety.
- `close` returns `None` after a rejection because the stf swapped in a
  private machine (`rollups_machine.rs:283-294`, `machine_stf.rs:312-315`),
  which `rotate_reverted` relies on (`advance.rs:428-429`): a cross-module
  protocol carried by comments.
- Positioning uses the batch type and rotation verbs
  (`machine_stf.rs:715-756`), so `advance.rs` is the clone chain of two
  publishers, not only the runner's writer role (`advance.rs:4-8`).

## Boundary verdict

Real on crash consistency: publication and the one-transaction commit live
in storage; the runner is a thin scheduler (plan, loop, paging, floor). The
`advance.rs`/`snapshots.rs` split is partly historical: the rotation verbs
serve crossings too (`advance.rs:348-352`, `412-415`, `483-503`), and
`snapshots.rs` is not the single home of loads it claims. Runner versus
manager is a real concurrency boundary (two threads, one store, one table),
held by Q3 and `docs/node-architecture.md:437-452`.

## Docs versus code

1. `snapshots.rs:4-5` and `docs/node-architecture.md:292-293`: every store,
   load and clean goes through `snapshots.rs`. Loads also at
   `machine_stf.rs:167`, `314`, `rollups_machine.rs:257`, `274`, `299`;
   removals at `stored.rs:105-117`, including the poisoned clone dropped with
   its `Machine` (`machine.rs:43-46`). Stale.
2. `docs/node-architecture.md:337-345` lists the overhead as close, clone,
   shared reload, removal. The rejected path also pays a private load and
   root hash (`machine_stf.rs:314-320`). Its 26/22 ms (also
   `docs/todo.md:20-21`) differs from the baseline's 24.2/21.1 ms
   (`docs/measurements/measurements.md:62-63`), and "removal 3" ms has no row
   there (`measurements.md:43-46` has no removal column).
3. `docs/node-architecture.md:303-305`: at most one transient checkpoint plus
   one working clone. In `rotate_accepted` the old checkpoint, the new one and
   the new clone coexist until `advance.rs:377`; `mod.rs:78-79` admits it.
4. `docs/dimensioning.md:243-245` prices the per-input overhead at 0.14-0.2 s
   (v0.22.0) in the per-input contract; the same doc reports 22-26 ms on
   v0.23 (`dimensioning.md:77-81`). `docs/todo.md:41-46` re-derives the
   reference price but does not name this section.

## Defended mechanisms

- Adopt-and-resync publication (`snapshots.rs:100-134`): a post-rename crash
  converges by replay, no recovery protocol; costs one private load and hash
  per batch (`snapshots.rs:109`). Reopen if the store stops being
  content-addressed.
- `Volatile`/`Durable` (`stored.rs:1-25`): the emulator's two-halves rule as
  a type property, in 154 lines.
- The roll's in-transaction guard (`advance.rs:526-531`): the only storage
  check that a sealed epoch's inputs held still (`ingest.rs:49-93` refuses
  no late input). Fatal cursor asserts (`snapshots.rs:54-98`): P2, a wrong
  cursor would be silent. FULL sync: GC removal is an external effect of a
  commit (`open.rs:32-38`).

## Candidate changes

1. Enforce Q3: in `publish_crossing`'s transaction, assert the cursor's epoch
   exceeds `batch.epoch`. Premise: the ordering spans two components.
   Evidence: `advance.rs:499-503`, `snapshots.rs:195-202`. Buys a tripwire if
   the manager ever builds a Hero before settlement. Costs about five lines
   and a read in the insert transaction; breaks nothing documented. Reopen if
   the ordering becomes a type. Confidence: medium.
2. Fix Docs versus code 1-4. Prose only. Confidence: high.
3. Q7: `bench_runner` (`examples/measure.rs:377-454`) times only
   `process_rollup` in total (`measure.rs:432`, `442`). Major faults and block
   writes need no new machinery: `peak_rss_bytes` already calls `getrusage`
   (`measure.rs:666-680`); `ru_majflt` and `ru_oublock` deltas around `timed`
   are about ten lines. Caveat: kernel writeback of shared mappings may not
   be charged to the process, and macOS semantics differ, so bytes written
   stays approximate (the free-space delta at `measure.rs:476` measures
   allocation). Confidence: medium.
4. Per-phase runner times: not without instrumenting production code, since
   the rotation steps are private to storage. `bench_clone_loop`
   (`measure.rs:271-327`) times clone, shared load, advance, root hash and
   close of a raw chain, but not the removal, the rejected path's private
   load, the stride-2^38 collect or publication. Extend it (a removal column,
   a rejected row) rather than the runner. Confidence: medium.
5. Not worth it: skipping the batch's last rotation (clone and load that
   `mod.rs:261` drops unused; one per 64 inputs, and it special-cases the
   record verbs); dropping the second proof validation (`advance.rs:581-587`
   repeats `rollups_machine.rs:366-367`; one guards capture, the other the
   write-once cell, both cheap).
6. Q6: keep the floor (`mod.rs:70-94`, `159-161`) here. The runner is the
   one component that maps shared clones in bulk and can defer work, and the
   failure it prevents is SIGBUS with nothing logged. Its cost is the
   `settled` predicate's consensus knowledge (`advance.rs:41-42`, `177`).
   Keep the terminal page (`mod.rs:242-246`, `263-270`): only the runner sees
   the awaiting-to-terminal transition, in about ten lines. Neither is a
   reader or operations feature. Confidence: medium.

## Not verified

Emulator internals (clone, sync and rename durability), taken from the
binding docs (`machine.rs:246-294`); the measured figures (nothing re-run);
the reader's sealed-epoch guard; the Hero's use of the positioner beyond
`hero/actor.rs:152`; that every start path runs `initialize` and its sweep;
root-hash counts for inputs running past the first sample (rule from
`ruler.rs:505-513`); rusage block-output semantics on Linux and macOS.
