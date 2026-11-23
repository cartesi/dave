# Card: Hero (honest dispute strategy)

Scope: `cartesi-rollups/node/src/hero/`. Production lines (before each file's
`#[cfg(test)] mod tests`): `mod.rs` 30, `context.rs` 284, `planner.rs` 239,
`actor.rs` 491 (of which about 33 are inline `#[cfg(test)]` items: the
`reobservations` counter and `with_tail`), `action.rs` 466, `gc_planner.rs`
119; total 1,629. Test lines: 19, 126, 540, 145, 638, 189; total 1,657. Tests
are now 50 percent of the directory (July: 59 percent).

## Possible correctness bug

None met. One recorded lead is still live in the code and is listed under
Candidate changes 5 (cleanup skipped while a non-root loss is reported).

## Owns

- The per-tick dispute decision: one `HeroDecision` (Terminal, Wait or Act)
  per tick (`cartesi-rollups/node/src/hero/planner.rs:18-23`, `:110`).
- The join gate: Foam proposes, Solid must re-derive the identical join
  (`cartesi-rollups/node/src/hero/actor.rs:210-245`).
- The two epoch anchors: the epoch-start hash, read once from the store at
  `actor.rs:143-147`, and the pinned geometry, read at `actor.rs:150`
  (`context.rs:36-39`).
- The path projection from the event fold to a `SemanticSnapshot` plus
  per-level `LevelCoords` (`context.rs:46-49`, `:65-164`).
- Fulfilment of an intent into calldata material (`action.rs:125-177`) and
  its mapping to one lane request (`actor.rs:358-490`).
- Cleanup selection when the Hero waits (`gc_planner.rs:30-39`,
  `actor.rs:321-342`).
- The missed-obligation classification (`planner.rs:57-70`), logged at
  `actor.rs:260-268`. No doc names it.
- The Hero owns no durable state. The epoch manager holds one `Hero` per
  current epoch in memory (`epoch_manager/mod.rs:38`), builds it lazily
  (`:568-577`) and drops it at epoch completion (`:148`).

## Takes

- Chain, through `StateReader::fetch_from_root`
  (`tournament/reader.rs:87-123`). It returns Foam: Solid advanced to the
  finalized head, then cloned and extended to latest. The Hero trusts fold
  completeness, which is a trusted RPC property (`docs/node-architecture.md:151-162`).
- Standings at one head, through `read_standings`
  (`tournament/observer.rs:149-182`), called at `actor.rs:302` (Foam) and
  `:221` (Solid).
- The live phase and timeout classification of each engaged clocked or
  sealed-leaf match, through `read_match` (`observer.rs:208`), at
  `context.rs:114-121`. For a delegated match it reads nothing: it validates
  the child's descriptor against the parent's (`observer.rs:224-235`,
  `:469-491`).
- The bond, through `read_bond` at the action head (`actor.rs:375`).
- The store: `snapshot_hash(epoch, 0)` and `sling_config().geometry`
  (`actor.rs:143-151`). The `Storage` is opened by the manager
  (`epoch_manager/mod.rs:569`) and moved into
  `DisputeSource::on_store` (`actor.rs:152`). That function re-reads the
  config and opens a second connection for the positioner
  (`engine/machine_stf.rs:667-687`).
- The engine: local commitments through `DisputeSource::node`
  (`context.rs:90`); openings, proofs and transition proofs at
  `action.rs:188-190`, `:242-250`, `:282-295`, `:312-314`, `:351-357`. The
  Hero trusts their output and checks only that the material is consistent
  with itself (see Q7).
- Shutdown, through `source.stop_on` (`actor.rs:111`).

## Gives

- To the epoch manager: a `HeroTick` with an optional terminal result, the
  latest head it was observed at, and at most one `LaneRequest`
  (`actor.rs:37-71`). The manager sends the request into the wave
  (`epoch_manager/mod.rs:209`). The terminal result gates the sentry claim
  and staging (`:223-247`) and the loss report (`:585-597`, `:606-641`).
  Promise: settlement reads at `head()` describe the block of the win
  (`actor.rs:62-63`, `docs/epoch-lifecycle.md:291-294`).
- To the lane: calldata built by `tournament::sender` functions
  (`actor.rs:376-488`, `:336-340`). Promise: one verb per tick and no error
  path that picks a second verb (`actor.rs:355-357`).
- To e2e: the `submit Hero action:` info lines, which serve as sync points
  (`actor.rs:364-366`).

## Invariants

1. At most one request per tick: the Hero's action, or one cleanup only
   when the Hero waits (`actor.rs:247-280`; the match arms are exclusive).
   Breaking it would put several of the Hero's own transactions behind one
   another at consecutive nonces.
2. A join's payload comes only from Solid, and only when Solid's whole
   decision equals Foam's (`actor.rs:213-242`; `HeroIntent::Join` carries
   the commitment so that equality covers it, `planner.rs:77-83`). Breaking
   it locks a bond behind a stale claim (`docs/node-architecture.md:655-667`).
   Harness: `harness/tests.rs:659`, `:771`, `:777`.
3. An intent is prepared from the same context that produced it
   (`actor.rs:242`, `:251`). A mismatch is a node bug and panics
   (`action.rs:237`, `:278`, `:341`, `:371-376`, `:381-383`).
4. Every level on the path runs the pinned table's stride and height. This
   is an assert (`context.rs:241-258`), called at `context.rs:87` for every
   visited level, on Foam and on Solid. Tests: `context.rs:322`, `:332`,
   `:340`. If it fails, stored window roots and the settlement hash no
   longer match the game (trust assumption on the parameters provider,
   `docs/node-architecture.md:196-198`).
5. The root starts from the node's own epoch-start state. This is a
   `Fatal::terminal` error (exit 30), not a panic (`actor.rs:289-300`; exit
   code at `fatal.rs:71`; the manager propagates it at
   `epoch_manager/mod.rs:259`). I found no test that reaches it. The exit
   mapping alone is tested (`lib.rs:219-239`).
6. A child is bounded by its parent before the engine computes the child's
   commitment (`context.rs:110-121` ordering, `observer.rs:224-230`).
   Without it a lying child descriptor would reach the engine's coordinate
   asserts.
7. A level's base cycle is aligned to its span. This is checked as an error
   (`context.rs:269-275`) ahead of the `LevelCoords::new` assert
   (`engine/dispute.rs:44-49`). Test: `context.rs:346`.
8. The planner is pure: no provider, no machine (`planner.rs:3-5`). The
   signature enforces it (`plan_hero(&SemanticSnapshot)`, `:110`). The
   chain-free table tests depend on it.
9. Preparation makes no provider reads; only the join's bond is read, at
   submission (`action.rs:27-31`, `actor.rs:375`). Test: `actor.rs:526`.
10. A timeout disposition outranks the match phase (`planner.rs:181-192`).
    Test: `planner.rs:482`.
11. A tick whose assembly ran machine work observes once more before
    planning (`actor.rs:186-200`). Harness: `harness/tests.rs:543` checks
    `reobservations == levels`.

## Concurrency and crash consistency

The Hero runs inside the epoch manager's async tick, on one task, and never
concurrently with itself. Machine work runs under `machine_work`
(`hero/mod.rs:23-29`): `block_in_place` on the multi-threaded runtime, so
the reader and runner tasks keep running. Machine work happens at
`context.rs:90` (once per level, per assembly: up to three assemblies per
tick, `actor.rs:187`, `:199`, `:222`) and at `actor.rs:251` (prepare). Only
the first assembly's machine work triggers a re-observation
(`actor.rs:186-188`). A build during the Solid assembly at `:222` does not;
`docs/node-architecture.md:709-713` records "once" as deliberate.

kill -9: the Hero writes nothing itself. The engine writes the quartet
cache, and its crash consistency is the engine card's. A request already
handed to the lane is either in the pool or not; the lane is stateless and
the next tick re-plans from the chain. Restart: the manager builds a new
Hero lazily (`epoch_manager/mod.rs:568`), and the reader refolds Solid from
the root's creation block (`reader.rs:125-129`).

State held across ticks in memory, and what its loss costs (Q3):
- `StateReader.solid` (`reader.rs:39-43`): a refold from the root's
  creation block, which costs reads and response-clock time behind a
  provider that caps log ranges (`docs/node-architecture.md:593-600`). It is
  dropped on purpose on a contradiction (`reader.rs:71-84`, `actor.rs:174-176`).
- `DisputeSource` (`actor.rs:75`; fields at `engine/dispute.rs:214-227`):
  the store handle, the in-memory `frontier`, and the positioner's
  `fed_windows` and `spawned` counter (`machine_stf.rs:641-653`). Loss
  costs a rebuild from the store. `spawned` is read only as a delta within
  one tick (`actor.rs:186-188`).
- `anchors`, `epoch`, `root_tournament` (`actor.rs:76-78`): re-read from
  the store and the finalized epoch row.
- `reobservations`: test-only (`actor.rs:80-81`).

Tick-to-tick decision dependence: none found. No field records a past
decision or intent. `HeroTerminal` is not latched: each tick recomputes it,
and a later standing can move a "lost" child level back to propagation (the
standing is checked before the local standing, `planner.rs:111-141`). The
manager's `planned` map (`epoch_manager/mod.rs:155-158`) depends on
previous ticks but gates only logging and paging. The one carried value
that shapes a decision is Solid. It is a pure function of finalized chain
data, except that a bad finalized prefix survives until a contradiction or
a restart (`docs/node-architecture.md:600-615`). That matches the doctrine:
the loss costs reads, not correctness.

## What it knows about its neighbours

- Tournament fold (`Dispute`, `CommitmentPosition`, `MatchStatus`;
  `context.rs:19-25`, `gc_planner.rs:14-17`): needed, since the Hero walks
  the fold.
- Hero-only domain types in `tournament/domain.rs`: `SemanticSnapshot`
  (`:433`), `ParentLink` (`:399`), `LocalCommitmentStanding` (`:314`),
  `Engagement` (`:273`), `GcIntent` (`:488`). Outside `src/hero/`, grep finds
  them only in `domain.rs` itself. Their placement is a leak in the
  reverse direction: Hero policy types live in the tournament module.
  `ParentLink.parent_match` and `parent_side` (`domain.rs:401-403`) have no
  accessor and no reader anywhere in `src/`. Only derived `PartialEq`
  touches them. The comment at `context.rs:126-129` says the link "names
  this level's match"; the planner reads only `parent_commitment` and
  `parent_tournament` (`planner.rs:127-133`).
- Engine (`DisputeSource<Positioner>`, `LevelCoords`, `Level`,
  `TournamentGeometry`, `Quartet`, `RulerFactory`; `context.rs:17`,
  `action.rs:15`, `:407`): the Hero does quartet arithmetic itself
  (`coords.node(height, pos)`, `contested.children()`, `coords.root()`;
  `action.rs:281`, `:408`, `:426-428`, `:395`). This is needed to select the
  divergent branch. A narrower engine call ("open the node at height h,
  position p") would hide `Quartet`, but the gain is small.
- Storage: the Hero itself reads two values (`actor.rs:143-151`) and then
  hands the connection to the source. It does not need a connection of its
  own; the manager could pass the anchors. See Candidate 7.
- Lane: `LaneRequest = (String, TransactionRequest)` (`provider.rs:355`),
  built by `sender::*` from a `DynProvider` (`sender.rs:25-31`, `:152-158`).
  The Hero needs the provider only to build calldata. That is a narrowable
  dependency, but harmless.
- Epoch manager: the Hero assumes it is constructed only after the epoch's
  settlement row exists (`epoch_manager/mod.rs:204`). Otherwise
  `snapshot_hash(epoch, 0)` could be absent and `actor.rs:146` panics with
  `expect`, which only store corruption reaches.

## Boundary verdict

The internal split is real, not historical. `planner.rs` is pure policy and
gives a chain-free decision table. `context.rs` is the one place where chain
reads and the engine's commitment builds meet the policy. `action.rs` is the
machine-work fulfilment. `actor.rs` sequences these and owns the two
cross-cutting rules: the Solid join gate and re-observation after a build.
The Hero/manager boundary is also real. The Hero owns the dispute's clock
path. The manager owns settlement, refunds and the lane, and it gates
staging on the Hero's terminal result at the same head. `gc_planner.rs` is
actor-neutral and could live beside the fold. Its placement in `hero/`
follows its only caller and costs nothing. The weak boundary is the
domain-type placement noted above: the types that define the Hero's input
live in `tournament/`.

## Docs versus code

- `docs/node-architecture.md:87-91` says both the descriptor check and the
  root initial-hash check "are invariant violations and panic". The code
  panics only for the descriptor (`context.rs:249`). The initial-hash check
  is `Fatal::terminal`, exit 30 (`actor.rs:290-300`). The same doc already
  says exit 30 at `docs/node-architecture.md:170-172`, and the code comment
  `context.rs:29-34` agrees with the code.
- `docs/epoch-lifecycle.md:263` says cleanup is proposed "when the tick
  selected no Hero action and the root is still running". The code proposes
  it only on `Wait` (`actor.rs:259-274`). A terminal `Lost(Eliminated)` or
  `Lost(Child)` while the root runs yields no cleanup (`actor.rs:275-278`).
  This is the recorded lead `docs/reviews/2026-10-13-prt-cyber-verification/HONEST-NODE-CONTRACT.md:125-130`.
  That frozen record cites `TournamentResult::Running`, which no longer
  exists.
- `docs/epoch-lifecycle.md:274-276` names only the root loss. The code also
  classifies and logs elimination and a child win by another class
  (`planner.rs:33-44`, `epoch_manager/mod.rs:630-639`).
- Concept found only in code: missed obligations (`planner.rs:57-70`, four
  waits logged as ERROR every tick at `actor.rs:260-268`). No doc in
  `docs/*.md` or the node README names them.
- `docs/dimensioning.md:490-494` (claim instead of proof is not implemented)
  matches the code: `SealedLeaf` always plans `ProveLeaf` (`planner.rs:210`).

## Q1. One tick

1. `Hero::tick` (`actor.rs:172`) calls `plan_tick`, which records `trips`
   (`:186`).
2. Observe (`:187`, `observe` at `:283`): `fetch_from_root` advances Solid
   to F and builds Foam to latest (`reader.rs:87-123`). Initial-hash check,
   exit 30 (`actor.rs:289-300`). Foam standings at latest (`:302`).
3. Assemble Foam's path (`:303-312`, `context.rs:65-164`). Per level:
   pinned check (`:87`), coordinates (`:88`), MACHINE WORK
   `source.node(root)` (`:90`), position, then `check_candidate` (`:103`)
   or `read_match` (`:114`), and descend into a delegated child (`:130-133`).
4. If `trips` moved, RE-OBSERVE once (`actor.rs:188-200`).
5. Plan on Foam (`:208`, `planner.rs:110`).
6. If the plan is a join: read Solid's standings (`actor.rs:221`), assemble
   Solid's path (`:222-231`, machine work, usually cached), plan on Solid
   (`:232`). If the decisions differ, return an empty tick (`:233-240`).
7. Act: PREPARE under `machine_work` (`:251`, `action.rs:125`). Then
   `request_prepared` (`actor.rs:257`, `:358`) reads the bond for a join
   (`:375`) and builds the `LaneRequest`.
   Wait: log the reason (`:260-272`), then `gc_request` (`:273`, `:321-342`).
   Terminal: return the result (`:275-278`).
8. Hand-off: `HeroTick` (`:280`), then the manager's wave
   (`epoch_manager/mod.rs:209`), then `submit_wave` (`:156`).

## Q2. Decision table (planner.rs)

Every decision is planned on Foam (latest) except the join, which also
needs Solid (finalized) to plan the identical `Join` (`actor.rs:213-242`).
Cleanup and `at` use Foam and the latest block number (`actor.rs:273`).
Standing is checked first, at each visited level:
- RootWinner, local commitment: Terminal Won (`:112-114`). RootWinner,
  another commitment: Lost(Root{final_state}) (`:116-118`).
- RootFailed: Terminal FailedNoWinner (`:120-121`).
- InnerWinner, same parent commitment: Act PropagateChild (`:132-135`).
  Another: Lost(Child) (`:127-130`).
- InnerEliminable: Wait ChildEliminable [missed] (`:137-138`).
- MatchesActive or AwaitingClosure: fall through (`:140`).

Then the local standing:
- NotJoined, joins accepted (MatchesActive{accepts_joins} or
  AwaitingClosure, `domain.rs:386-393`): Act Join (`:145-149`). Otherwise:
  Wait JoinsClosed [missed] (`:151`).
- Candidate: Wait CandidateBlockedByMatches or AwaitingTournamentClosure
  (`:155-161`).
- Eliminated: Lost(Eliminated) (`:165-169`).
- Engaged, by timeout disposition (`:181-192`): the local side wins, Act
  ClaimTimeout (`:229`). The other side wins, Wait OpponentWinsByTimeout
  [missed] (`:225-226`). EliminateBoth, Wait MatchEliminable [missed]
  (`:189`).
- Engaged with no timeout, by phase (`:194-216`): Bisecting gives Advance,
  ReadyToSealLeaf gives SealLeaf, ReadyToDelegate gives CreateChild, each
  when the local side is the responder; otherwise Wait OpponentTurn
  (`:232-237`). SealedLeaf gives ProveLeaf with no responder check
  (`:210`). AwaitingChild recurses into the child (`:211-215`).

## Q4. Panics and exit 30

The descriptor assert (`context.rs:241-258`) is reached from the root
descriptor (`observer::read_descriptor` on a cold fold, `reader.rs:129`)
and from child descriptors carried by `NewInnerTournament` events. Before
descent, `read_match` checks that a child sits one level down, on a parent
leaf (`observer.rs:224-230`, `:469-491`). Stride and height themselves are
trusted to the parameters provider, so only a broken trust assumption
reaches the assert.

The initial-hash check is not a panic: it returns exit 30 at
`actor.rs:289-300` on every `observe`. It is reached only once the manager
builds the next epoch's Hero, which needs that epoch's settlement row
(`epoch_manager/mod.rs:204`). So the runner first executes the whole next
epoch from the node's own state, and only then does the node stop. That is
added latency on an already-defeated protocol; it is not a defect.

## Q5. Losses and missed obligations

Classification: `planner.rs:33-44`. Detection: Root at `:116`, Eliminated at
`:166`, Child at `:128`. Logging: `epoch_manager/mod.rs:606-641`, once per
tick. The split between "won with this node's final state" and "divergence"
happens there (`:610-628`), comparing against `settlement.final_state`.
Missed waits are detected at `planner.rs:151` (JoinsClosed), `:226`
(OpponentWinsByTimeout), `:189` (MatchEliminable) and `:138`
(ChildEliminable), and logged at ERROR every tick at `actor.rs:260-268`.

## Q6. gc_planner

It plans `EliminateMatch` for any clocked or leaf match with
`at >= eliminable_at` from events (`gc_planner.rs:60-74`), and
`EliminateChild` for a child whose standing is `InnerEliminable`
(`:75-90`). An eliminable child replaces its subtree (`:79-93`). The
deepest work wins, and tree order breaks ties (`:110-118`). It is
load-bearing for liveness because a root finishes only with no live
matches. Sybil-versus-Sybil matches need `eliminateMatchByTimeout`, which a
third party can call only on double elimination
(`HONEST-NODE-CONTRACT.md:144-149`). The protocol assumes some actor does
this cleanup (`docs/dispute-game.md:62-63`), and the delay bound assumes it
is prompt (`docs/dispute-game.md:343-344`). Beyond liveness, the module adds
the depth/order priority (about 15 lines) and a `MissingTournament` error
for a node bug (`:54-56`, `:76-78`). Both are cheap. No Sybil-winner
propagation is planned, by recorded decision (`docs/epoch-lifecycle.md:267-273`).

## Q7. Intent versus prepared call

`HeroIntent` names only the targets (`planner.rs:73-103`).
`PreparedArenaAction` holds the openings and proofs (`action.rs:33-81`).
`prepare` re-checks no chain phase: an intent/context mismatch panics
(invariant 3). It still checks local material:
- each opening hashes to its parent (`require_opening`, `:439-457`);
- the join's last-leaf proof has the right position and opens the root
  (`:191-197`);
- the local node at the contested position equals the chain's
  `revealing_parent` (`:285-292`, `:412-419`);
- some branch diverges (`:305`, `:434`);
- the agree-state proof opens the local root and matches the right branch
  (`:315-320`).

Only engine non-determinism or a corrupt quartet cache reaches these.
Collision resistance binds the revealed nodes to the local root. Each check
costs a hash join. They turn what would be a reverted, paid call (a leaf
proof's calldata up to about 3.76M gas, `docs/node-architecture.md:756-759`)
into a named tick error, which the manager escalates after G.

## Q9. Tests

All 10 planner tests are chain-free and table-driven (`planner.rs:364-749`):
terminal priority, join/wait, candidate waits, elimination, timeout
outranking phase, the sealed-leaf winner, an exhaustive no-timeout phase
table (`:566`), child recursion, propagation versus Lost(Child), and child
elimination. The 3 gc tests are chain-free too (`gc_planner.rs:187`,
`:214`, `:269`), as are the 6 context tests (`context.rs:322-366`: the
pinned table, coordinates, leaf-to-root assembly). The 8 action tests run
on a toy `DisputeSource<ToyFactory>`, with no chain and no machine
(`action.rs:515-524`, `:837-1066`). The one actor test uses a recording
provider (`actor.rs:525-528`). The tick itself (observe, the join gate,
re-observation) is covered only by the anvil harness
(`harness/tests.rs:543`, `:659`, `:771`, `:777`).

## Q10. Claim instead of proof

The planned behaviour would go in `plan_engagement`'s `SealedLeaf` arm
(`planner.rs:210`), which today plans `ProveLeaf` unconditionally. The
planner has no input for it yet: `LiveMatch` carries only the phase and a
timeout disposition (`domain.rs:252-255`). The opponent's remaining leaf
clock would need an observer read beside `classifyMatchTimeout`
(`observer.rs:236-244`), and the planner would need a proof-latency
figure. Tracked in `docs/todo.md:92-98`.

## Defended mechanisms

- The Solid join gate (`actor.rs:210-245`). Premise: the contracts accept a
  join over any commitment with a valid last-leaf proof, so a stale join
  locks a bond (`docs/node-architecture.md:655-667`). Costs: one extra
  standings read and one assembly when a join is planned. Reopen if joins
  gain a cancel path.
- Re-observation after machine work (`actor.rs:186-200`). Premise: a leaf
  build takes tens of minutes, and a child may finalize meanwhile
  (`docs/node-architecture.md:709-713`). Costs: one more observation, with
  no rebuild.
- The pure planner and separate intent and prepared types
  (`planner.rs:18-103`). They buy a chain-free decision table of 540 test
  lines and a single dispatch seam (`actor.rs:355-357`).
- The local tripwires in `prepare` (Q7): cheap, and reachable only by
  node bugs.
- `machine_work` (`mod.rs:16-29`), with a regression test (`mod.rs:37`).

## Candidate changes

1. Fix `docs/node-architecture.md:87-91` to say exit 30 for the
   initial-hash check. Premise: the code at `actor.rs:290-300`. Buys a
   consistent failure policy. Costs nothing. Confidence: high.
2. Drop `ParentLink.parent_match` and `parent_side` and correct the comment
   at `context.rs:126-129`. Premise: no reader exists
   (`domain.rs:399-428`; grep finds none). Buys 6 to 10 lines and one
   false claim. Risk: none, unless a lead-21 fix wants them. Confidence:
   high.
3. Move `SemanticSnapshot`, `ParentLink`, `LocalCommitmentStanding`,
   `Engagement` and `GcIntent` from `tournament/domain.rs` into `hero/`.
   Premise: they have no consumer outside `hero/`. Buys a truthful
   boundary: the tournament module stops carrying actor policy types.
   Costs churn across 6 files and the tests. Confidence: medium.
4. Pass only `TournamentGeometry` to `HeroContext::assemble`. Premise:
   `anchors.initial_hash` is read only in `actor.rs:291`, and the context
   reads only the geometry (`context.rs:87`). Not worth it: the struct is
   4 lines, and its doc (`context.rs:29-34`) is useful.
5. Plan cleanup on a terminal `Lost(Eliminated | Child)` while the root
   runs. This is the recorded lead `HONEST-NODE-CONTRACT.md:125-130`,
   tracked at `docs/todo.md:97-98`; recorded, not reopened. Today's site is
   `actor.rs:275-278`. It matters only after the node has already missed an
   obligation, and only while the child runs. Either fix it or align
   `docs/epoch-lifecycle.md:263` with the code. Confidence: medium.
6. Batch every due cleanup instead of one per tick. Premise: prompt
   cleanup is a delay-bound assumption (`docs/dispute-game.md:343-344`).
   Against: cleanups ride consecutive nonces ahead of the next due Hero
   action (`actor.rs:234-235` states that concern for the join), and other
   actors can clean too. Not worth it without a measurement showing that
   one cleanup per poll interval stretches settlement under a Sybil flood.
   That measurement would reopen it. Confidence: low.
7. Let the manager pass the anchors and stop handing the Hero a `Storage`
   only to forward it. Premise: `actor.rs:143-152` and
   `machine_stf.rs:669`, `:678` already re-read the config and open a
   second connection. Not worth it: it saves a few lines but moves an
   epoch-start invariant into the manager.
8. Add a harness regression for exit 30 at `actor.rs:289-300`. Premise: I
   found no test that reaches it in `src/harness`, `src/epoch_manager` or
   `tests/`. Buys a guard on the one stop of an already-defeated protocol.
   Costs a seeded divergent-predecessor fixture. Confidence: medium.

## Not verified

- The history of the October removal of re-validation in `prepare`: I read
  only the current code (`action.rs:1-9`).
- Engine-side crash consistency of the quartet cache written during
  `source.node`, and the `frontier` rebuild cost.
- Harness tests at `harness/tests.rs:543`, `:659`, `:771`, `:777`: checked
  by name and one assertion line, not read in full.
- The `tournament::sender` bodies beyond their signatures, and how the
  observer decodes standings (`decode_standing`).
- Whether any e2e scenario reaches exit 30.
