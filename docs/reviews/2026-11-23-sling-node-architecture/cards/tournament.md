# Card: tournament (how the node observes a dispute on chain)

Scope: `cartesi-rollups/node/src/tournament/`, production lines only:
`mod.rs` 13, `reader.rs` 484 (tests from 485), `observer.rs` 604 (tests from
605), `domain.rs` 589 (tests from 590), `dispute.rs` 489 (tests from 490; the whole fold is production), `sender.rs`
194 (no tests). About 2,370 production lines.

## Possible correctness bug

None met inside the trust model. One heal gap outside it (RPC completeness is
trusted), recorded as candidate 1: a `DisputeError` raised while extending
Foam does not drop Solid (`reader.rs:115-121` returns the error as is; only
`advance_solid` drops, `reader.rs:170-180`). If Solid missed a log at or
below F and the next event of that match lands in `F+1..H` (an omitted
`MatchCreated` followed by a `MatchAdvanced`), every Foam fold fails with
`UnknownMatch` and the Hero's tick fails (`hero/actor.rs:284`) until that
later event finalizes and the Solid extension drops the prefix. That is up to
one finality lag (about 13 minutes on Ethereum) of no Hero action, more than
G. The doc says such a log "drops Solid in process"
(`docs/node-architecture.md:600-603`); in code that holds only once it
surfaces in the finalized range. Confidence in the trace: high. Severity: low,
since it needs a provider that omits logs.

## Owns

- The finalized prefix `Solid { root, head, dispute }` (`reader.rs:32-37`),
  the only cross-tick state, in `StateReader.solid` (`reader.rs:39-43`).
- The fold rules: what a tournament event does to the tree and which event it
  refuses (`dispute.rs:262-374`, errors `dispute.rs:459-488`).
- The harvest checks over one `eth_getLogs` answer (`reader.rs:303-375`).
- The ABI-to-domain narrowing of every tournament view the Hero uses
  (`observer.rs:113-604`) and the domain value types (`domain.rs:14-525`).
- The tournament write-side encoding (`sender.rs:25-194`).
- Not owned here: the Hero's path (`hero/context.rs:65-164`), the pinned-table
  check (`hero/context.rs:241-257`), base-cycle alignment
  (`hero/context.rs:262-273`), the root initial-hash check
  (`hero/actor.rs:289-300`), cleanup policy (`hero/gc_planner.rs:30-39`), bond
  recovery's own tree walk (`epoch_manager/recovery.rs:76-95`).

## Takes

- From the epoch manager, via `Hero::new`: root address and creation block
  (`epoch_manager/mod.rs:570-574`, `hero/actor.rs:153`), both from
  ingestion's stored epoch row. Trusted: the root is the consensus's.
- From the chain (`chain.rs`): finalized and latest heads with hash
  (`chain.rs:80-130`), logs by address list and range (`chain.rs:135-147`),
  and the provider for pinned calls (`chain.rs:63`). Trusted: completeness
  of a successful log answer and truthfulness of pinned reads
  (`docs/node-architecture.md:160-162`). Checked: response shape and fork
  consistency at the heads (see Invariants).
- From the Hero: the error of a failed tick (`hero/actor.rs:172-178`), which
  `forget_contradicted_solid` inspects (`reader.rs:71-84`).

## Gives

- `fetch_from_root` -> `(H, Foam)` (`reader.rs:87-123`): a `Dispute` folded
  through latest H, a clone of Solid extended by `F+1..H`; disposable.
- `solid()` -> `(F, &Dispute)` (`reader.rs:59-63`) for the join cross-check
  (`hero/actor.rs:217-242`).
- `read_standings` (`observer.rs:149-182`): one `TournamentStanding` per
  tournament reachable through live `Inner` matches, pinned to the given head.
- `read_match` (`observer.rs:208-307`): a validated `LiveMatch` for one live
  match; `check_candidate` (`observer.rs:185-200`); `read_bond`
  (`observer.rs:130-137`); `read_descriptor` (`observer.rs:113-126`).
- `Tournament::position` (`dispute.rs:231-259`): any commitment's place.
- `sender::*` -> `LaneRequest` (`sender.rs:25-194`), consumed by
  `hero/actor.rs:321-342` and `hero/actor.rs:358-490`.

### Chain interface consumed (Q2; also the minimal interface for a watcher)

Structure from events (all from `Tournament`, decode in `reader.rs`):
- `CommitmentJoined(commitment)` `reader.rs:398-403`
- `MatchCreated(one, two, eliminableAt)` `reader.rs:404-413`
- `MatchAdvanced(matchIdHash, eliminableAt)` `reader.rs:414-420`
- `LeafMatchSealed(matchIdHash, eliminableAt)` `reader.rs:421-427`
- `NewInnerTournament(matchIdHash, childTournament, descriptor)`
  `reader.rs:428-440`, descriptor narrowed by `observer.rs:331-347`
- `MatchDeleted(one, two, reason, winnerCommitment)` `reader.rs:441-464`
- Decoded for ABI conformance and dropped: `StandingChanged`
  `reader.rs:465-468`, `PartialBondRefund` `reader.rs:469-472`,
  `BondRecovered` `reader.rs:473-476`. Any other topic fails the harvest
  `reader.rs:477-480`. These nine are every event `Tournament` emits
  (`prt/contracts/src/ITournament.sol:262-446`).

Point reads, pinned by block hash (`chain.rs:39-41`):
- `tournamentDescriptor()` root only, at F, cold fold only
  (`observer.rs:118-125`, called `reader.rs:129`).
- `tournamentStanding()` every reachable tournament, at H; also at F before
  a join (`observer.rs:161-174`; `hero/actor.rs:302`, `hero/actor.rs:221`).
- `classifyMatchTimeout(Match.Id)` per engaged clocked/leaf match on the
  Hero's path (`observer.rs:237-248`).
- One of `bisectingMatch` / `readyToSealMatch` / `sealedMatch(matchIdHash)`
  by the classified phase (`observer.rs:253-297`).
- `bondValue()` at the action head, joins only (`observer.rs:130-137`,
  `hero/actor.rs:375`).

Anything else: `eth_getBlockByNumber(finalized|latest)` (`chain.rs:115-130`)
and multi-address `eth_getLogs` with range bisection (`chain.rs:135-147`).
Outside this module but needed by a watcher: the root address and creation
block from the consensus's `EpochSealed` (ingestion). Not consumed though
available: `NewInnerTournament.bondValue` and the bisection payload that
`MatchAdvanced` carries (`ITournament.sol:286-298`).

## Invariants

1. Solid is a fold of finalized blocks only, through `solid.head`. Enforced
   by construction (`reader.rs:163-187` uses the finalized head) and the
   same-height hash check (`reader.rs:144-152`). Breaks: Foam and joins built
   on a non-final prefix.
2. A Solid that cannot absorb a finalized event is never kept: `DisputeError`
   drops it (`reader.rs:177-179`); transport, harvest and decode errors keep
   it (`reader.rs:171-176`). Test `reader.rs:1779-1842` and the candidate
   drop test ending `reader.rs:1773`. Breaks: an infinite failing tick.
3. Every kept log was requested from its address, lies in `[from, head]`,
   has block number, nonzero hash and index, is unique by `(block, index)`,
   agrees on hash with every other log of its block in the harvest, carries
   the head's hash at the head's height, and for a child created in this
   harvest is not below its creation (`reader.rs:244-249`, `reader.rs:325-374`).
   Breaks: folding a mixed fork or a duplicated response.
4. Logs fold per tournament in `(block, log_index)` order (`reader.rs:276`,
   `reader.rs:377-384`); a level is folded before its children are read
   (`reader.rs:252-265`). No cross-tournament ordering is needed, because a
   standing derives from each commitment's latest match (`dispute.rs:231-259`).
5. A resolved match holds no child: `MatchDeleted` replaces `Inner{child}` by
   `Resolved` (`dispute.rs:345`, `dispute.rs:107-112`), so a resolved
   subtree is never read again (`reader.rs:260-265`).
6. Every descriptor has nonzero height and `stride + height < 256` with no
   cycle overflow (`domain.rs:64-98`). Fronts the engine's U256 shifts.
7. A live match handed to the Hero passes `validate_match_geometry`
   (`domain.rs:527-588`, called `observer.rs:305`) and a delegated child
   passes `validate_child_geometry` (`observer.rs:469-491`) before the
   Hero computes its commitment (`hero/context.rs:110-121`). Fronts the
   asserts in `LevelCoords::node` (`engine/dispute.rs:68-77`) and the
   `children` expect (`domain.rs:534-537`).
8. One phase per match at one block: event status, `classifyMatchTimeout`
   phase and projection phase must agree (`observer.rs:249`,
   `observer.rs:434-462`, `observer.rs:497-504`, `:520-527`, `:548-555`).

## Concurrency and crash consistency

- One owner: the epoch manager's async task drives `Hero::tick`, which owns
  the `StateReader` (`hero/actor.rs:79`); no locks, no shared state.
  Standing reads run up to 16 at once (`observer.rs:42`, `:178`); log chunks
  run sequentially (`chain.rs:142-145`). Writes: none.
- Nothing is persisted (Q1 confirmed: `reader.rs:6-10`; no storage or SQLite
  use in `src/tournament/`, the reader holds `Chain`, a block number and
  `Option<Solid>`, `reader.rs:39-43`). The Hero's own connection lives in
  `DisputeSource` (`hero/actor.rs:152`, `epoch_manager/mod.rs:569`).
- Q1, Solid and Foam lifecycle. Solid lives in `StateReader.solid`, inside
  `Hero`, inside `EpochManager.epoch_hero` (`epoch_manager/mod.rs:38`),
  across ticks. Foam lives one tick in `Observation`
  (`hero/actor.rs:283-318`) and is dropped with it. Solid is dropped (a) on a
  `DisputeError` while extending it (`reader.rs:177-179`); (b) when a failed
  Hero tick's error chain holds `EventPhaseMismatch` or
  `EventCandidateMismatch` (`reader.rs:71-84`, `hero/actor.rs:174-176`),
  reached through `ContextError`'s `#[source]` (`hero/context.rs:189`,
  `:204-210`); (c) with the Hero at epoch completion
  (`epoch_manager/mod.rs:148`); (d) at process exit. Refold happens on the
  next `fetch_from_root`: root descriptor at F, then fold from the root's
  creation block (`reader.rs:127-131`), each level from its earliest
  creation in the harvest (`reader.rs:222-231`).
- Restart cost: one descriptor call, then per tree level
  `ceil(n/100)` `eth_getLogs` over `[earliest creation, F]`, each split in two
  on failure (`docs/node-architecture.md:520-525`), then the Foam tail. A
  child resolved before F is never requested. kill -9 at any point leaves
  nothing behind; the restart redoes the fold and re-plans the same step.

## What it knows about its neighbours

- Hero: `domain.rs` holds Hero-relative types: `Engagement`
  (`domain.rs:271-299`), `LocalCommitmentStanding` (`:309-319`), `ParentLink`
  (`:397-428`), `SemanticSnapshot` (`:430-484`), and the cleanup intent
  `GcIntent` (`:486-497`). They are the planner's input, built only in
  `hero/context.rs`. Placement leak, not a logic leak (Q5): the module does
  not compute the Hero's path; `hero/context.rs:79-158` walks it with
  `Tournament::position`. `read_match` and `check_candidate` are shaped for
  that walk but take any match or commitment.
- Engine: comments name the U256 shift and the `children` expect
  (`domain.rs:74-75`, `:534-537`); the checks are needed fronts (Invariants
  6, 7). It knows nothing of levels in the table, strides of the table, or the
  pinned table; that check lives in `hero/context.rs:241-257`.
- Storage: none (Q5 confirmed).
- Transaction lane: `sender.rs` returns `provider::LaneRequest`
  (`sender.rs:13`, `provider.rs:355`), a type alias; needed.
- Chain: `MAX_FILTER_ADDRESSES` and range bisection are `chain.rs`'s
  (`chain.rs:48`, `:142`); the reader only groups by level.

## Boundary verdict

Real. It is the dispute's trust boundary: raw logs and ABI views in, values
in domain types out, and every check that stands between a chain value and
an engine assert sits here or in `hero/context.rs`. Its inner split also
follows real seams: `dispute.rs` is a pure, test-routable fold with no RPC;
`reader.rs` owns RPC-shape and fork checks plus the Solid lifecycle;
`observer.rs` owns pinned reads and their narrowing; `sender.rs` is the write
half of the same ABI. The historical part is `domain.rs` carrying the Hero's
planner vocabulary (candidate 2).

## Docs versus code

- `docs/node-architecture.md:600-603` says an omitted finalized log that
  surfaces at the match's next event drops Solid; code drops only when it
  surfaces in the Solid extension, not in Foam (`reader.rs:115-121` vs
  `:167-181`). See Possible correctness bug.
- `docs/node-architecture.md:173-180` makes "the observer" check base-cycle
  alignment and the pinned table; those are in `hero/context.rs:262-273` and
  `hero/context.rs:241-257` (the observer has the per-match, child-level and
  child-leaf checks, `observer.rs:469-491`, `domain.rs:527-588`).
  `docs/node-architecture.md:87-92` places the pinned check correctly.
- `docs/node-architecture.md:636-640` lists point reads (root descriptor,
  standings, phase payload) and omits `bondValue()` (`observer.rs:130-137`),
  read at the join's action head (`hero/actor.rs:375`).
- Two walks of one tree: the fold here and the recovery walk over
  `NewInnerTournament` (`epoch_manager/recovery.rs:76-95`). Recorded
  decision, not reopened (`docs/node-architecture.md:639-642`): recovery
  needs resolved children the fold drops.
- Concept only in code: `HarvestValidation.created` (`reader.rs:307-310`),
  the per-harvest creation map, is documented only as its effect
  (`docs/node-architecture.md:585-587`). Fine.

## Defended mechanisms

- Solid/Foam split with join from Solid only (`hero/actor.rs:210-245`):
  a join is the one stale call that locks a bond behind an undefended claim;
  argued at `docs/node-architecture.md:655-667`.
- Cold refold instead of repair: no reverse-apply or reconciliation code; a
  restart and a contradiction take the same path (`reader.rs:65-84`,
  `:125-131`). Costs refetch time on long disputes; buys one code path and
  no inherited bad prefix.
- Per-level multi-address harvest (cartesi/dave#306, `reader.rs:204-268`):
  RPC count scales with depth, not tournament count; the earliest-creation
  start (`reader.rs:222-231`) stops a late child from being read over the
  whole dispute, and the creation check (`reader.rs:336-345`) is the price of
  reading siblings over blocks where they did not exist.
- Head hash pin plus intra-harvest hash agreement (`reader.rs:362-372`):
  cheap fork detection; ancestry below H unproven by recorded decision
  (`docs/node-architecture.md:622-624`), not reopened.
- Q8: the phase contradiction (`observer.rs:434-462`) and the candidate check
  (`observer.rs:185-200`, call `hero/context.rs:99-105`) are detection (P2),
  not cross-validation. Each guards a silent omission on the Hero's path: a
  missed pairing leaves the node waiting as a false candidate while its clock
  runs; a missed delegation would otherwise fail every tick with
  `MatchChildTopology` (`observer.rs:563-566`) without dropping Solid. Both
  cost no extra RPC beyond reads the Hero makes anyway.

### Validation layers (Q3)

Kinds: (a) stops the fold or decoder from guessing, (b) fronts an engine or
planner assert, (c) re-proves a contract rule.
- Harvest (`reader.rs`): address grouping `244-249`, removed/number/range/
  hash/index/duplicate/hash-agreement/head-pin/creation `325-374`, unknown
  topic `477-480`, unknown reason or winner `448-459`: all (a), RPC shape or
  ABI generation.
- Fold (`dispute.rs`): root level 0 `416-419` (a); duplicate join `267-272`,
  unknown commitment `283-290`, unknown match `365-374`, not clocked
  `352-363`, already resolved `339-344`: (a). Deletion reason and winner are
  deliberately not checked (`dispute.rs:329-331`).
- Observer: discriminants `415`, `422-431`, `569-593` (a); projection phase
  `497-504`, `520-527`, `548-555` (a), since a projection's payload is zero
  off-phase (`ITournament.sol:836-866`); `StandingKindMismatch` `354-356`,
  `365-408` (b), fronts `planner.rs:124-126` and the `expect` at
  `observer.rs:386`; `require_candidate` `595-603` (a); resolved match
  `221-223` (b); leaf tournament delegating `227-229` (b), fronts
  `hero/context.rs:248`; child geometry `469-491` (b); sealed on non-leaf
  `563-566` (b); event phase and candidate: detection.
- Domain: descriptor `64-98` (b); bisecting height `538-540`, height range
  `552-554`, alignment `565-568`, position range `571-574` (b), fronting
  `engine/dispute.rs:69-77`; cycle `576-585` (b) for a sealed leaf, whose
  cycle feeds `prove_transition` (`hero/action.rs:352-356`).
- Kind (c) that remains: `ResponderParityMismatch` (`domain.rs:555-563`;
  the responder only feeds an equality in `planner.rs:232-237`); the cycle
  check for unresolved matches (`domain.rs:576-585`; production reads only
  `leaf_position` there, `hero/action.rs:281`, `:408`);
  `InnerWinnerOutsideParentMatch` (`observer.rs:385-391`; the planner already
  maps a foreign parent commitment to a loss, `planner.rs:127-131`).

### domain.rs consumers (Q6)

Matched on by the planner: `TournamentStanding` (`planner.rs:111-141`),
`LocalCommitmentStanding` (`planner.rs:143-174`), `TimeoutDisposition`
(`planner.rs:181-192`), `LiveMatchState` (`planner.rs:194-217`), `MatchSide`
(`planner.rs:232-237`); `GcIntent` in `hero/actor.rs:332-341`. Read but not
matched: `UnresolvedMatch`, `WaitingChildren`, `SealedDivergence`,
`MatchCoordinate`, `Engagement`, `ParentLink`, `RootWinner`, `InnerWinner`
(`hero/action.rs:281-356`, `planner.rs:112-135`). Only carried to logs:
`MatchDeletionReason` and `InnerEliminationReason` (`planner.rs:40`, `:54`).
Constructed and never read in production: `InnerWinner.child_commitment`
(`domain.rs:345-361`, no accessor), `ParentLink.parent_match` and
`parent_side` (`domain.rs:399-428`, no accessors), `SealedDivergence`'s
`leaf_position`, and `UnresolvedMatch.coordinate.cycle`.
`TournamentKind` is used only inside `tournament/` in production.

### Caps and pins (Q7)

- 100-address cap: `chain.rs:44-48`, applied `chain.rs:142`. Defends
  liveness against providers' address-list limits (geth 1,000); a provider
  refusing 100 fails every range, a stated provider requirement
  (`docs/plans/provider-requirements.md:82-85`).
- Per-level harvest: `reader.rs:216-266`; buys RPC count by depth.
- Creation-block check: `reader.rs:282-285` records, `reader.rs:339-345`
  enforces; defends against a mixed-fork answer giving a sibling logs before
  it existed, which the level's earlier start makes requestable.
- Hash pin at F and H: `reader.rs:368-372` against the phase head (F at
  `reader.rs:163-166`, H at `reader.rs:115`); plus `reader.rs:99-107` and
  `:144-152` at equal heights. Defends against a range served from another
  fork whenever the head holds a tournament log.

### Memory (Q9)

No node-side bound. Per tournament: one `Commitment` per join in a HashMap
(`dispute.rs:182`, `:273-279`) and one `Match` per `MatchCreated` in a Vec,
kept after resolution (`dispute.rs:183`, `:292-295`, `:345`). Each match ends
with at least one elimination, so matches stay below joins; each join pays a
bond (contract), and the join window closes. Children exist only behind live
`Inner` matches and are freed at resolution (`dispute.rs:345`). Lookup is a
linear scan (`dispute.rs:213-217`, `:365-374`), so a fold is quadratic in a
tournament's matches. Up to three copies coexist in a tick: Solid, its clone
for extension (`reader.rs:159`), and Foam (`reader.rs:118`). The bound is
economic (bonds per join), which is the same bound the contracts rely on.

## Candidate changes

1. Drop Solid on a `DisputeError` from the Foam extension too. Premise: such
   an error, like a phase contradiction, may mean Solid missed a log. Evidence
   `reader.rs:115-121` vs `:177-179`. Buys: closes the up-to-finality-lag
   stall above and makes `docs/node-architecture.md:600-603` true; about 5
   lines. Costs: a mixed or reorged Foam tail that fails to fold now costs a
   cold refold, the price already accepted for phase contradictions
   (`reader.rs:69-70`). Breaks nothing documented. Reopen if refolds on a
   flaky provider prove costly. Confidence: medium.
2. Move `Engagement`, `LocalCommitmentStanding`, `ParentLink`,
   `SemanticSnapshot` and `GcIntent` (`domain.rs:271-319`, `:397-497`) into
   `hero/`. Buys: `tournament/` holds only chain-shaped values; about 200 lines
   move, no concept removed. Costs: import churn in tests. Reopen if a second
   consumer of these types appears. Confidence: medium.
3. Delete never-read fields `InnerWinner.child_commitment`,
   `ParentLink.parent_match`, `ParentLink.parent_side`. Buys about 10 lines
   and constructor arguments. Costs: test fixtures change
   (`planner.rs:711`, `hero/action.rs:802`). Reopen if propagation starts
   checking the pairing that `hero/context.rs:126-129` says it trusts.
   Confidence: medium.
4. Remove the remaining kind (c) checks: responder parity and the unresolved
   cycle check. Premise P2: a lying read that keeps parity passes anyway;
   the contracts always satisfy both, so they only add a P1 hazard if the
   contract semantics ever moved within one ABI. Buys about 20 lines.
   Costs: a corrupt read would plan a wrong turn instead of failing a tick
   (reverts or waits). Keep `InnerWinnerOutsideParentMatch`: it guards a
   terminal loss decision (`planner.rs:127-131`). Confidence: low; taste.
5. Derive standings from `StandingChanged` instead of `tournamentStanding()`
   reads. Not worth it: it re-implements the contract's finish and expiry
   logic in the node (`ITournament.sol:428-444`), exactly the re-proving P2
   prunes, and one read per tournament is bounded concurrency.
6. Use `NewInnerTournament.bondValue` for child joins. Not worth it: the root
   needs the read anyway; one call per join.
7. Re-read a contradicted phase at F before dropping Solid, to spare refolds
   on Foam lag. Not worth it until refold cost is measured to matter.
8. Move `sender.rs` to `hero/` or next to `provider.rs`. Not worth it: it is
   the write half of the tournament ABI; the lane is contract-agnostic apart
   from revert naming (`provider.rs:848-858`).
9. Index matches by id hash. Not worth it: counts are bond-bounded, and Vec
   order gives `gc_planner` its stable tie-break (`gc_planner.rs:110-117`).

## Not verified

- Did not read `chain.rs` range bisection (`logs_bisecting`) or the
  `MAX_FILTER_ADDRESSES` test beyond `chain.rs:436-449` references.
- Did not trace how `report_loss` handles `Loss::Child`
  (`epoch_manager/mod.rs:591`), so the impact of a false child loss is a lead.
- Did not run tests; the drop tests are cited from reading
  (`reader.rs:1730-1842`). The `CandidateMismatch` call-site has no direct
  regression, as `hero/context.rs:100-102` says.
- Did not verify the bound "matches below joins" against `Tournament.sol`.
