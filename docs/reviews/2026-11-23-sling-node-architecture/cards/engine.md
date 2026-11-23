# Card: engine (commitment construction and proofs) and merkle

Scope: `cartesi-rollups/node/src/engine/` production lines (`#[cfg(test)]`
modules excluded): `structure.rs` 242, `ruler.rs` 554, `cache.rs` 176,
`dispute.rs` 510 (about 45 of them `#[cfg(test)]` Tail items),
`machine_stf.rs` 828, `config.rs` 126, `geometry.rs` 121, `constants.rs` 44,
`stf.rs` 106, `mod.rs` 56: about 2760. Test-only: `spec.rs` 1671, `toy.rs` 334
(`mod.rs:43-46`). `merkle/`: `mod.rs` 24, `tree.rs` 196, `tree_builder.rs`
141, `digest/mod.rs` 95, `digest/keccak.rs` 21: about 480.

## Possible correctness bug

None met. Traced and found sound: chain coordinates into `LevelCoords::node`
and `Quartet::children` (Q5 below); the Store feeder on a span crossing fed
windows (reachable only on a store without window-root rows,
`dispute.rs:247-255`); an oversized input (the emulator's
`send-cmio-response.cpp` at the pinned commit makes it a no-op, leaving the
machine yielded, which `ruler.rs:199` idles); an epoch starting terminal
(never reached: a terminal epoch never settles, `docs/epoch-lifecycle.md:104-115`,
so `machine_stf.rs:156-159` cannot stall a later epoch).

## Owns

- The meta-cycle layout and shape predicates (`structure.rs:78-89`, `126-144`).
- Every leaf convention: fused feed, closing ureset, idle replay, padding,
  window tripwire (`ruler.rs:8-39`, `181-242`).
- Witness encoding (`machine_stf.rs:589-631`) and its pre/post checks
  (`dispute.rs:337-357`).
- Quartet compute policy: 8-level fanout (`cache.rs:25-27`), tall threshold
  and span resume (`cache.rs:67-70`, `101-144`).
- The level-0 composition `level0_tree` (`dispute.rs:116-131`), shared by
  settlement (`storage/advance.rs:569`) and frontier (`dispute.rs:392`).
- Geometry validator (`geometry.rs:37-76`) and config row codec
  (`config.rs:64-125`; DDL is storage's, `config.rs:7-12`).
- Emulator shims (Q6). Process memory only: `Frontier.top` (`dispute.rs:171`),
  `revert_tail`, `checkpoint`, `ucycle` (`machine_stf.rs:90-103`),
  `Positioner.spawned` (`machine_stf.rs:648`).

## Takes

- Inputs: `input_count` (`dispute.rs:257`, `machine_stf.rs:671`), payloads by
  `Storage::input` (`machine_stf.rs:395-401`, `545-550`, `725-732`); trusts
  ingestion's contiguity.
- Boundaries: `nearest_boundary_at_or_before`, `snapshot_hash`
  (`machine_stf.rs:765-788`); distrusts the directory, re-hashes on load
  (`machine_stf.rs:790-798`).
- Window-root rows: `window_root_count/range` (`dispute.rs:258`, `386`),
  strict (`dispute.rs:265-270`, `storage/dispute.rs:119-134`).
- Pinned config (`dispute.rs:231`, `machine_stf.rs:669`).
- From the Hero: `LevelCoords` from a descriptor (`hero/context.rs:260-283`),
  heights, leaf offsets, the disputed meta-cycle and both state hashes
  (`hero/action.rs:352-356`); trusts the observer's validators (Q5).
- From the runner: a live `Machine` at a window boundary, payload, boundary
  path (`machine_runner/mod.rs:220-225`).

## Gives

- Hero: `DisputeSource` (Q4). Promises a node hash equal to stepping every
  transition, bottom-up siblings (`dispute.rs:473-502`), a witness only after
  both state checks.
- Runner: root-stride runs (`machine_runner/mod.rs:237-240`), `took_revert`
  (`machine_stf.rs:250`).
- Storage: `fold_runs` (`storage/advance.rs:97`), `level0_tree` (`:569`),
  `Quartet`, `Run`, `InputBoundary`, `awaits_input` (`storage/open.rs:166`),
  `LOG2_INPUT_WINDOW_SPAN` (`storage/rollups_machine.rs:214`), `UARCH_STATE_*`
  (`storage/open.rs:153`). Startup: `TournamentGeometry`, `EngineConfig`
  (`args.rs:6`).

## Invariants

1. A quartet row is final; recomputation must agree. Collision assert
   `storage/dispute.rs:160-180`, exercised on each cold descent
   (`dispute.rs:453-461`). Without it nondeterminism is silent.
2. No input crosses its window. Emulator budget; tripwire `ruler.rs:65-70`
   (called at `218`, `302`, `438`). Else the shape is undefined.
3. Frontier rows equal the input count or are absent (`dispute.rs:262-271`).
4. Settled and defended level-0 roots are one function (`level0_tree`, both
   call sites above). A drift loses the root tournament.
5. A started machine hashes to its boundary row (`machine_stf.rs:790-798`);
   a revert checkpoint to its revert root (`machine_stf.rs:319-324`).
6. Witness bytes leave only after both checks (`dispute.rs:343-355`).
7. The pinned table tiles 2^92 and the root stride lies in [2^20, 2^68]
   (`geometry.rs:44-74`; re-asserted `dispute.rs:232-239`).
8. Bulk equals stepped tall leaves: tests only (`tests/engine_machine.rs:1690`,
   `machine_stf.rs:1287`).

## Concurrency and crash consistency

- One `DisputeSource` per Hero epoch, run under `block_in_place`
  (`hero/mod.rs:23-29`; calls `hero/context.rs:90`, `hero/actor.rs:251`). The
  runner uses `Ruler` on its own thread. Both write `sling_nodes`; conflict
  plus collision check makes duplicates benign (`storage/dispute.rs:46-49`).
- A hero holds three SQLite connections: the source's, the Positioner's
  (`machine_stf.rs:678`), and one per positioning for the Store feeder
  (`machine_stf.rs:814`).
- kill -9 in `compute_and_store`: the fanout is one transaction
  (`cache.rs:87`, `storage/dispute.rs:50-51`). In `build_tall`: one row per
  finished span (`cache.rs:140`), resumed after (`cache.rs:119-122`, test
  `tests/engine_machine.rs:2032`). In a crossing: only `publish_crossing`
  registers a boundary (`machine_stf.rs:754`, `storage/advance.rs:499-503`);
  restart crosses again (`tests/engine_machine.rs:1578`).
- Memory-only state costs at most one replay and carries no correctness
  machinery; `spawned` only triggers re-observation (`hero/actor.rs:186-200`).

## What it knows about its neighbours

Q1. The layering `Stf -> Ruler -> cache -> DisputeSource` (`mod.rs:14-27`)
holds in its main direction. Reach-arounds:

1. `ruler.rs:41` imports `fold_runs` from `dispute.rs`: innermost layer on
   the outermost. Leak (a merkle helper).
2. `Stf` carries the bulk collector (`stf.rs:72-86`); the ruler branches on
   it (`ruler.rs:299-326`). Needed: idle stretches stay with the ruler.
3. `cache.rs` knows the tall path and threshold (`cache.rs:67-70`, `138`) and
   polls `interrupted` (`cache.rs:123`). Needed for resumable 2^38 builds.
4. `Feeder::Store` holds a `Storage` (`machine_stf.rs:64-69`) and reads inputs
   inside the Stf (`machine_stf.rs:395-401`, `545-550`). Leak: one window,
   so a payload would do (candidate 1).
5. `Positioner::cross` (`machine_stf.rs:715-756`) drives storage's clone chain
   (`begin_crossing`, `rotate_accepted`, `rotate_reverted`,
   `publish_crossing`, `storage/advance.rs:353-503`) and
   `take_machine/put_machine` (`storage/rollups_machine.rs:335`, `344`),
   re-implementing the runner's per-input loop (`machine_runner/mod.rs:216-260`)
   minus the collect. Knowledge needed (`machine_stf.rs:711-714`: no 410 MiB
   store per window), placement historical.
6. `impl DisputeSource<Positioner>` sits in `machine_stf.rs:660-704`, through
   `pub(super)` accessors (`dispute.rs:300-306`).
7. Two structure sources: pinned (`dispute.rs:231`) and
   `Structure::PRODUCTION` (`machine_stf.rs:668`); equal by the startup pin
   check (`config.rs:9-11`).
8. The Hero reaches below the facade: `Quartet::children`
   (`hero/action.rs:426`), `LevelCoords::node` (`hero/action.rs:281`, `408`),
   and is generic over `RulerFactory` (`hero/action.rs:125`).

## Boundary verdict

`DisputeSource` is a real boundary: the chain-facing Hero on one side, on the
other a deterministic, restartable compute cache whose only durable state is
write-once rows, with local crash consistency (one transaction per fanout,
one row per span). `Stf`/`Ruler` is real for testability: the toy checks
every convention against a literal oracle (`spec.rs:4-9`). The Positioner is
historical: storage and runner choreography placed in the engine because only
it built a factory; the knowledge is needed, the location is not.

## Docs versus code

- `mod.rs:24-26`, `dispute.rs:10-13`: level 0 served from "window-root rows
  plus lazy interior folds" of recorded runs. Runs are never persisted
  (`storage/advance.rs:87-89`); below window height the machine serves
  (`dispute.rs:359-366`). Stale; likewise `dispute.rs:89-92` ("the facade
  folds window interiors on demand": callers are only `dispute.rs:127,130`,
  `ruler.rs:276`, `storage/advance.rs:97`) and `machine_stf.rs:684-686`.
- `docs/computation-hash.md:48-52` names `Structure::decompose` the one
  authority; `constants.rs:20` feeds production `window_height`
  (`storage/rollups_machine.rs:213-215`). Window height has three formulas:
  there, `dispute.rs:122`, `dispute.rs:376-378`.
- `docs/computation-hash.md:321-322` and `machine_stf.rs:8-10` call
  `Collector::Stepped` the test reference; production runner and crossing use
  it (`machine_stf.rs:228`), meaning "skip the revert-tail collect".
- `docs/computation-hash.md:317-322` ("Only such tall quartets use the
  collector"): every Bulk-mode dispute feed calls it for the revert tail
  (`machine_stf.rs:425-433`). Minor.

## Defended mechanisms

- Idle-span capture and replay (`ruler.rs:341-383`): an idle region can be
  2^48 big cycles. Pinned by `tests/engine_machine.rs:734`.
- 8-level fanout (`cache.rs:25-27`): a full descent costs span / (1 - 2^-8).
- Span-resumable tall build (`cache.rs:92-144`): a two-level leaf build runs
  tens of minutes (`hero/actor.rs:189-190`).
- Frontier fold (`dispute.rs:148-172`): above window height a node crosses the
  input frontier; only a fold avoids a whole-epoch replay.
- Two collectors (recorded, `docs/computation-hash.md:321-322`, `371-376`) and
  window-root rows over the emulator's forest (recorded,
  `docs/computation-hash.md:377-381`): not reopened.
- Panicking corruption tripwires (`dispute.rs:259-261`, `machine_stf.rs:316-324`,
  `777-798`): an Err would retry forever on the clock path.
- Serial per-step hashing (`machine_stf.rs:105-118`), measured nine times faster.
- Generic `Structure`/`Stf`: one trait and a struct buy 32 spec tests over
  tiny structures (`spec.rs:24-40`), compiled out of production.

## Answers to the specific questions

Q2. `Scratch`: in production only the placeholder `resume` installs
(`machine_stf.rs:180-184`), replaced before any feed (`machine_stf.rs:813`);
its arms (`machine_stf.rs:362-384`, `544`) never run in production. Used by
`tests/engine_machine.rs:738`, `1255`, `1293`, `1342`, `1481`, `1715`,
`machine_stf.rs:1023`, `examples/measure.rs:500`, `826`. Test support compiled
into production, because `tests/` and `examples/` cannot see `#[cfg(test)]`;
splitting needs a cargo feature for about 40 lines. `Store`: dispute
positioning only (`machine_stf.rs:813`). `Advance`: runner
(`machine_runner/mod.rs:220`) and crossing (`machine_stf.rs:733`). `Bulk`:
disputes (`machine_stf.rs:662`) and the `resume` default (`:176`), hence
measure and scratch tests. `Stepped`: runner and crossing
(`machine_stf.rs:228`); tests at `tests/engine_machine.rs:281`, `1669`, `1713`
and `machine_stf.rs:914`.

Q3. The runner collects each window at the pinned root stride
(`machine_runner/mod.rs:237-240`), folds the runs to one root
(`storage/advance.rs:96-108`), and commits it as an ordinary quartet row at
(epoch, root stride, window height, shift = window)
(`storage/rollups_machine.rs:221-232`, `storage/advance.rs:453-471`). At the
roll, the settlement root is `level0_tree` over those rows plus a padding
window folded from the final boundary hash (`storage/advance.rs:554-571`).

At dispute time `Frontier` (`dispute.rs:162-172`) reads the same rows as a
strict prefix (`dispute.rs:256-271`) and serves every root-stride quartet at
or above window height by walking the memoized `level0_tree`
(`dispute.rs:367-408`); below window height, real or padding window, the
machine serves as at any nested level. One concept with one composition home,
but its coordinate is split: window height and the row quartet live in
storage (`storage/rollups_machine.rs:213-232`), the engine recomputes the
height twice, and the prefix queries are storage's
(`storage/dispute.rs:62-138`).

Q4. Definitions; Hero call sites. `on_store` `machine_stf.rs:661`;
`hero/actor.rs:152`. `stop_on` `machine_stf.rs:693`; `hero/actor.rs:111`.
`trips` `machine_stf.rs:701`; `hero/actor.rs:186`, `188`. `node`
`dispute.rs:411`; `hero/context.rs:90`, `hero/action.rs:249`, `283`, `410`.
`children` `dispute.rs:431`; `hero/action.rs:242`, `294`, `395`, `421`.
`prove_leaf` `dispute.rs:476`; `hero/action.rs:313`. `prove_last`
`dispute.rs:505`; `hero/action.rs:189`. `prove_transition` `dispute.rs:337`;
`hero/action.rs:352`. `LevelCoords::new/root/node` `dispute.rs:45`, `60`, `68`;
`hero/context.rs:277`, `hero/action.rs:281`, `395`, `408`.
`Quartet::children` `structure.rs:225`; `hero/action.rs:426`. `set_tail`
(test) `dispute.rs:309`; `hero/actor.rs:132`. The epoch manager calls none;
it reaches the engine only via storage's settlement
(`storage/advance.rs:569`). The Hero names a quartet only to select a child
(`hero/action.rs:407`, `426`); leaf positions it needs anyway (chain
arguments). The pinned-level check (`hero/context.rs:241-257`) and base
alignment (`hero/context.rs:267-275`) could live in a `LevelCoords`
constructor from a descriptor.

Q5. Chain-reachable panics, then their front:
- `LevelCoords::new` `dispute.rs:47-51`: `hero/context.rs:267-275` (Err).
- `LevelCoords::node` `dispute.rs:69-77`: `validate_match_geometry`
  (`tournament/domain.rs:552`, `566`, `572`) at `tournament/observer.rs:305`;
  seal height 1 by construction (`tournament/observer.rs:533`).
- `children` expect `dispute.rs:432`, `hero/action.rs:426-428`: bisecting
  height at least 2 (`tournament/domain.rs:538-540`), root height nonzero
  (`tournament/domain.rs:73`).
- `prove_leaf` `dispute.rs:477-480`: position below tree size
  (`tournament/domain.rs:572`).
- `decompose` `structure.rs:79` via `prove_transition`: cycle check
  (`tournament/domain.rs:576-585`) plus pinned level (`hero/context.rs:249`).
- `Quartet::assert_valid` `structure.rs:193-204`: pinned table
  (`hero/context.rs:249`, `geometry.rs:45`, `53`); child shift
  `tournament/observer.rs:488`. Root shift: no validator; the root base cycle
  is trusted from the factory (`docs/node-architecture.md:180-181`). Flagged,
  documented.
- Window tripwire `ruler.rs:65-70`: no validator; the emulator budget fronts
  it (`docs/node-architecture.md:191-195`).
All others (`dispute.rs:265`, `273`, `machine_stf.rs:311`, `319`, `400`,
`731`, `790`) are reachable only from local state.

Q6. Emulator semantics re-implemented, and their pins:
- Terminal rule (`machine_stf.rs:288-298`); no emulator query exists. Pinned
  by `machine_stf.rs:1054`, `1160-1170`, the corpus
  (`tests/engine_machine.rs:519`), and the Solidity replay
  `cartesi-rollups/contracts/test/NodeWitnesses.t.sol:59`.
- HTIF yield decode (`machine_stf.rs:120-140`): avoids a guest-sized copy.
  Pinned by `machine_stf.rs:1490-1567`.
- Physical reload on RX_REJECTED (`machine_stf.rs:300-330`): the logged reset
  leaves the machine unreverted (`docs/computation-hash.md:213-217`). Pinned
  by `tests/engine_machine.rs:1278`, `1634`, `machine_stf.rs:1319`.
- Idle periodicity (`ruler.rs:341-383`, `stf.rs:55-61`): an optimization on
  the pristine-uarch assumption. Pinned by `tests/engine_machine.rs:734`.
- Saturated budget (`machine_stf.rs:493-497`, `513-523`). Pinned by
  `machine_stf.rs:1170`, `1287` and corpus case
  `uarch-budget-seam-accept-input-1` (docs only, not opened).

Q7. Bump `COMMITMENT_SEMANTICS` (`storage/sql/schema.rs:20`) for any change
of leaf values or shapes: `Stf` verbs (`stf.rs:14-15`), ruler conventions,
the fold or `Digest::join`, `Structure`. Geometry needs none (pinned,
`config.rs:35-37`). Guard: the golden fixtures fail with a reminder
(`tests/engine_machine.rs:80-96`, `machine_stf.rs:1272-1277`), but are
`#[ignore]` image tests (`tests/engine_machine.rs:592`) and
`UPDATE_FIXTURES=1` passes without a bump. No mechanical tie (candidate 4).

Q8. Production uses `MerkleBuilder` (`cache.rs:109`, `148`, `dispute.rs:97`),
`MerkleTree::{root_hash, subtrees, join, iterated}` (`cache.rs:173`,
`dispute.rs:138`, `tree_builder.rs:101`), `MerkleProof::{leaf, verify_root}`
(`hero/action.rs:192`, `309`, `316`), `Digest::from_data`
(`storage/rollups_machine.rs:73`). Test or example only:
`MerkleTree::prove_leaf/prove_last` (`tree.rs:151-195`; `spec.rs:997`,
`tests/engine_machine.rs:683`, `689`), `Digest::from_digest_hex`
(`examples/measure.rs:1415`). A port of
`prt/client-lua/cryptography/merkle_builder.lua` (same accumulated-count
cells and unsigned search, `merkle_builder.lua:46-89` against
`tree_builder.rs:76-136`), so not an independent fold check; the corpus is
(`docs/computation-hash.md:377-381`).

Q9. Confirmed `#[cfg(test)]`: `spec`, `toy` (`mod.rs:43-46`); `Tail` and the
overlay (`dispute.rs:180-209`, `225-226`, `308-332`, `412-415`, `435-441`,
`mod.rs:49-50`); `harness` (`lib.rs:31-32`); `with_tail`
(`hero/actor.rs:116`). They buy a literal leaf oracle (32 tests in
`spec.rs`), toy factories for hero preparation tests (`hero/action.rs:504`),
and an adversarial production Hero for the anvil harness
(`dispute.rs:174-179`). Production pays only generic parameters.

## Candidate changes

1. Give `Feeder::Store` the payload instead of a `Storage`, read once by the
   Positioner, and merge Store with Advance. Premise: Store feeds one window
   (`machine_stf.rs:391-394`). Evidence `machine_stf.rs:64-69`, `395-401`,
   `545-550`, `813-818`. Buys no storage in the Stf, one connection per
   positioning, one mode fewer. Costs one input read per positioning. Breaks
   no invariant. Reopen if a dispute stf must feed several windows. High.
2. Move `fold_runs` into `merkle` or `ruler` (`ruler.rs:41`). Clean layering
   for free. High.
3. One home for the window-root coordinate: move `window_height` and
   `window_root_quartet` (`storage/rollups_machine.rs:213-232`) beside
   `Frontier`; drop `dispute.rs:376-378` and the production use of
   `constants.rs:20`. One formula instead of three. Medium-high.
4. Pin the keccak of the commitment golden fixtures beside
   `COMMITMENT_SEMANTICS` in a non-ignored test, as `SCHEMA_PIN` does
   (`storage/sql/schema.rs:109-123`). Forces a decision on each
   regeneration; costs a pin bump on emulator bumps that change no
   semantics. Medium.
5. Move the crossing loop out of the engine into a storage/runner verb shared
   with `machine_runner/mod.rs:216-260`. One per-input loop; must keep the
   no-record rule (`storage/advance.rs:500`). Medium.
6. Put `Scratch` behind a feature. Not worth it: about 40 lines, and the
   tests' independent replay relies on it (`dispute.rs:251-253`).
7. An opening verb so the Hero never names a `Quartet`
   (`hero/action.rs:240-253`, `401-437`). Low; marginal.
8. Turn the coordinate asserts into errors. Not worth it: every chain-reachable
   one is fronted (Q5) and an Err retries forever on the clock path
   (`docs/node-architecture.md:163-167`).
9. Fix the stale "interior folds/runs" text (`mod.rs:24-26`,
   `dispute.rs:10-13`, `89-92`, `machine_stf.rs:684-686`) and the Stepped
   wording (`machine_stf.rs:8-10`). High.

## Not verified

- Emulator collector semantics (`collect_uarch_cycle_root_hashes`, periods,
  fixed points) beyond the node's comments; only `send-cmio-response.cpp` read.
- `spec.rs`, `toy.rs` beyond headers and counts; `examples/measure.rs`
  beyond grep; corpus case names (from the docs).
- Storage internals of crossing cleanup (`checkout`, `commit_clone`).
- No tests run.
