# Card: epoch manager

Scope: `cartesi-rollups/node/src/epoch_manager/mod.rs` (697 production
lines, 1-697), `cartesi-rollups/node/src/epoch_manager/recovery.rs` (199,
1-199), `cartesi-rollups/node/src/storage/completion.rs` (55, 1-55).
About 950 production lines. Neighbours read for evidence: `hero/actor.rs`,
`hero/planner.rs`, `hero/mod.rs`, `storage/queries.rs`, `storage/advance.rs`,
`escalation.rs`, `chain.rs`, `provider.rs` (`submit_wave`),
`tournament/reader.rs`, `IDaveConsensus.sol`, `ITournament.sol`.

## Possible correctness bug

None met. Traces checked and found sound:
- `done` implies an empty wave (assert at `epoch_manager/mod.rs:143`): `done`
  needs `settled` (`mod.rs:333`), which skips the Hero and settlement
  (`mod.rs:203`), and `refunds_complete` means `open` is empty
  (`recovery.rs:164`), and every candidate is also pushed to `open`
  (`recovery.rs:145-147`), so the recovery wave is empty.
- The two `?` foreclosure reads (`mod.rs:213-217`, `mod.rs:319-323`) can fail
  a tick after work was planned, but only when the Hero is terminal, whose
  tick carries no request (`hero/actor.rs:275-280`). The second read runs only
  when recovery is complete, so the recovery wave is empty too. Nothing
  prepared is lost.

Liveness note, outside the trust model (not a bug): after `Lost(Root)`, the
manager never stages, even when the winner ends in this node's final state.
It holds a proof for exactly that state (`mod.rs:231-247`, `mod.rs:612-618`).
If the winner never stages, the epoch waits for some other party. See
candidate 3.

## Owns

- The durable completion cursor `epoch_completion.next_epoch`. Its only
  runtime writer is `complete_epoch` (`storage/completion.rs:20-41`), called
  only at `mod.rs:149`. The seed write `seed_cursor_in`
  (`completion.rs:47-54`) runs once, at `storage/open.rs:360`.
- The lifetime of the epoch's `Hero` (`mod.rs:38`, built at `mod.rs:568-578`,
  dropped at `mod.rs:148`).
- Settlement intent: sentry claim, stage, accept (`mod.rs:363-552`).
- Bond-recovery intent and the in-memory `RecoveryTree` (`recovery.rs:54-61`).
- Batch assembly: one wave per tick, handed to `TransactionLane::submit_wave`
  (`mod.rs:156`).
- The exit-30 decision on finalized foreclosure (`mod.rs:317-329`).
- Per-call and per-epoch paging state: `planned`, `stall` and `stalled_now`
  (`mod.rs:42-46`).

## Takes

- From storage (the reader and runner write, the manager reads):
  - `unfinished_epoch()` (`storage/queries.rs:33-45`): the cursor joined with
    its `epochs` row. It returns None until ingestion has seen the cursor's
    seal.
  - `last_sealed_epoch()` (`queries.rs:47-61`).
  - `settlement_info(e)` (`queries.rs:143-145`). A row that does not decode
    or prove panics (`queries.rs:202-208`).
  - `next_input_id()` (`queries.rs:133-141`). It is used only to choose a log
    level.
  - The manager trusts these as finalized facts.
- From the Hero: a `HeroTick`, holding `result`, `head` and `request`
  (`hero/actor.rs:38-71`). The manager trusts `result` to be judged at `head`
  and `head` to be the latest block the result was read at.
- From the chain:
  - `finalized_head()` (`mod.rs:191`).
  - `isForeclosed`, at the Hero's head (`mod.rs:213-217`) and at finalized
    (`mod.rs:319-323`).
  - The DaveConsensus views `getSentryId`, `canAcceptStagedTournamentResult`,
    `hasSentryClaimedInEpoch` and `canStageTournamentResult`, each pinned to
    the Hero head's hash (`mod.rs:396-431`, `456-460`, `518-522`, via
    `ChainHead::block_id` at `chain.rs:38-40`).
  - The tournament's `NewInnerTournament` logs over a finalized range
    (`recovery.rs:82-88`).
  - `bondRecovery()`, read at the finalized hash (`recovery.rs:130-134`) and
    at latest (`recovery.rs:179-186`).
  - Log completeness and truthful pinned reads are trusted as RPC properties.

## Gives

- To the lane: an ordered wave of `LaneRequest` (`provider.rs:355`). The order
  is the Hero's action or cleanup first (`mod.rs:209`), then at most one
  settlement step (`mod.rs:249`), then every recovery (`mod.rs:304`). The
  manager promises each call was planned from this tick's observations. The
  lane promises one report per request, in order (`provider.rs:486-544`),
  which `track_planned` zips against (`mod.rs:663-666`).
- To the runner: through the cursor, permission to collect epochs below
  `min(cursor, machine_epoch)` (`storage/advance.rs:631-635`). The manager
  promises the Hero is dropped first (`mod.rs:147-149`).
- To the supervisor: `Fatal::terminal` (exit 30, `fatal.rs:71`) on finalized
  foreclosure with defense and recovery done, and it propagates the Hero's
  terminal error (`mod.rs:118`, `mod.rs:259`).

## Invariants

1. The cursor advances by exactly one, only for an ingested epoch. Enforced in
   one transaction (`completion.rs:22-38`) and by the schema CHECK
   (`storage/sql/schema.sql:54-58`). If it fails, an epoch is skipped and its
   bonds and settlement are abandoned.
2. The cursor advances only when ingestion shows a later seal at or below this
   tick's finalized head, AND a finalized recovery scan finds nothing open
   (`mod.rs:194-196`, `mod.rs:333`). Tests:
   `refund_completion_cannot_outrun_finalized_settlement` (`mod.rs:979-1006`)
   and `rotation_and_restart_...` (`mod.rs:911-976`). If it fails, the runner
   collects a live epoch, or a refund is lost after a reorg.
3. A Hero exists only for the cursor's epoch, after the roll, and is dropped
   before the cursor advances. Each half separately:
   - Cursor's epoch: the epoch passed to `Hero::new` comes from
     `unfinished_epoch` (`mod.rs:188`, `mod.rs:570-576`). Nothing re-checks a
     reused Hero's epoch (`mod.rs:568`). It holds because the cursor's only
     runtime writer sits right after the drop (`mod.rs:148-149`). That is a
     convention backed by a single writer, not a type or an assert.
   - After the roll: construction requires the `settlement_info` row
     (`mod.rs:204`). `roll_epoch` writes that row in the same transaction as
     the `(e+1, 0)` snapshot (`advance.rs:525-539`). So "row exists" equals
     "rolled". This is enforced by data.
   - Dropped first: statement order at `mod.rs:148-149`. If `complete_epoch`
     then fails, the Hero is gone and is not rebuilt, since `done` implies
     `settled`, which skips `react_dispute` (`mod.rs:203`). If this invariant
     fails, GC may delete the rows and snapshots under a live Hero
     (`advance.rs:631-645`).
4. Settlement invariant: staging asserts that the winner's commitment and
   final state equal the stored row (`mod.rs:478-487`). Acceptance asserts
   that the staged final state and outputs root equal it (`mod.rs:532-541`).
   Every view is pinned to the Hero's head. Test:
   `settlement_reads_the_block_the_hero_won_at` (`mod.rs:1104-1170`). A
   failure panics, by design. It is reachable only through a node bug or
   corrupt state.
5. Settlement calls target only the cursor's epoch. Every planner returns
   None when the view's `epochNumber` differs (`mod.rs:417`, `462`, `524`).
   Test: `mod.rs:1008-1067`.
6. Only finalized data completes recovery. `complete` comes only from the
   finalized-hash classification (`recovery.rs:129-165`); latest only
   suppresses (`recovery.rs:187-190`). Test: `recovery.rs:370-413`.
7. The `BondDisposition` mirror matches the Solidity enum (test at
   `recovery.rs:303-327`). An unknown value holds the epoch
   (`recovery.rs:151-159`).

## Concurrency and crash consistency

- One async task (`lib.rs:100-118`). The Hero runs inline on that task. Its
  machine work goes through `machine_work`, which uses `block_in_place` on the
  multi-thread runtime (`hero/mod.rs:22-28`), at `hero/actor.rs:251` and
  `hero/context.rs:90`. The reader and runner keep running. The Hero opens its
  own SQLite connection (`mod.rs:569`).
- A kill -9 mid-tick leaves either no durable write or the single cursor
  bump (`mod.rs:149`, one transaction). If the kill lands between the Hero
  drop and the bump, restart sees the same epoch again, recomputes
  `settled && complete` from the chain, and completes it.
- Held only in memory, each loss costing one tick or one walk:
  - The Hero: restart refolds from the root's creation (docs:
    `docs/epoch-lifecycle.md:278-283`).
  - `recovery`: one full walk (`recovery.rs:51-52`).
  - `planned` and `stall`: lost only as paging timers, so a restart delays a
    page by up to G.
- None of these gates a chain action. Restart test: `mod.rs:932-939`.

## What it knows about its neighbours

- Hero: `HeroTerminal`/`Loss` variants (`mod.rs:224-227`, `606-641`) and
  `HeroTick::head`. This knowledge is needed: settlement is keyed by the
  result, and loss reporting lives here. The Hero decides a win by
  commitment, not by signer: `winner.commitment() ==
  snapshot.local_commitment()` (`hero/planner.rs:113`). So a second honest
  node with another key, computing the same commitment, gets `Won` and stages
  and accepts. The root standing is checked first (`planner.rs:111-119`), so
  an eliminated sentry still votes once the root has a winner.
- The win head when the Hero joined: a terminal result always carries
  `latest_head` (`actor.rs:280`), never the Solid head, which is consistent.
- Consensus ABI: four views, three mutators, `IApplication::isForeclosed`
  (`mod.rs:199-202`), and the proof struct conversion (`mod.rs:681-696`).
  Needed.
- Tournament ABI: `bondRecovery`, `tryRecoveringBond`, `NewInnerTournament`,
  and a hand-mirrored enum (`recovery.rs:40-44`). Recovery decodes
  `NewInnerTournament` itself, through `Chain::decoded_logs_from_any`
  (`recovery.rs:82-88`, `chain.rs:168-183`), separately from
  `tournament/reader.rs:428-440`. The two do not share code, and should not
  be merged as they stand:
  - The reader folds every event type into a live `Dispute`.
  - The reader drops resolved children (`reader.rs:260-261`), while recovery
    needs exactly the resolved tournaments that still owe bonds.
  - Recovery must also run with no Hero, for historical epochs.
  - What they could share is the provenance rule itself (a child named only by
    a known parent's own event). Recovery restates it at `recovery.rs:92-93`;
    the reader encodes it in its fold. That is a small duplication, not a leak.
- Lane: the `LaneRequest` tuple, and `SendReport` fields for paging
  (`mod.rs:159-176`). The manager reads `verdict`, `nonce` and `tx_hash` only
  to format an error. That knowledge is needed for the page text, nothing
  else.
- `POINT_READ_CONCURRENCY` is borrowed from `tournament/observer.rs:42`
  (`recovery.rs:37`). This is a mild leak: a tuning constant shared across
  components.
- Storage: it reads the epochs, settlement_info and epoch_completion tables
  and the runner's boundary cursor (`next_input_id`, used only for a log
  level).

## Boundary verdict

The boundary is real. It is the only component that turns chain state and
the stored settlement into consensus-level intent, and it is the single
writer of the cursor that gates the runner's GC: a crash-consistency
boundary (invariant 3). It is also where the latest and finalized views are
reconciled into one batch per nonce base. The Hero/manager split is real for
the same reason: the Hero is per-epoch and disposable, while the manager
outlives epochs and handles epochs without a Hero (historical ones). The
recovery submodule is a separate concern with its own observation discipline
(finalized-complete, latest-suppress). It lives correctly inside the manager
because it gates the cursor.

## Docs versus code

- `recovery.rs:9-10` calls its walk "the same provenance-descended tree walk
  the dispute fold relies on". It is the same rule, implemented separately
  (`reader.rs:282-285`). The doc should say "the same provenance rule".
- `docs/epoch-lifecycle.md:231-233` says settlement calldata contents come
  from finalized inputs and stored data. Two fields do not:
  - The `epochNumber` argument of the claim and the accept comes from the
    latest view (`mod.rs:444`, `mod.rs:549`).
  - It is equality-guarded against the cursor epoch (`mod.rs:417`, `524`), so
    the bytes are identical and the claim holds in effect. Worth one clause in
    the doc.
- `docs/node-architecture.md:438-440` states the Hero/cursor invariant as a
  fact. The code holds it by statement order and a single writer, with no
  tripwire (invariant 3). The doc does not say which half is
  convention-backed.
- `docs/epoch-lifecycle.md:194-197` says "a sentry claims ... whoever won".
  The code agrees (`mod.rs:224-227`). It also says (`epoch-lifecycle.md:296-
  299`) that the correct state settles "once anyone stages it". This node
  will not stage it after `Lost(Root)` (`mod.rs:614-615`). That is
  consistent, but it is a choice the doc records without a reason (candidate
  3).
- The stall clock is one `Persistence` shared by every cause
  (`mod.rs:44`, `340-349`). The rule's prose (`node-architecture.md:203-215`)
  reads as if each failure has its own timer. A tick that alternates causes
  keeps one timer running, which pages earlier. That is harmless, but
  undocumented.
- `docs/epoch-lifecycle.md:204-216` and `node-architecture.md:671-699` match
  the code. Checked:
  - dispositions (`recovery.rs:144-160`)
  - finalized-only completion
  - in-memory tree
  - recovery during a contested root (`mod.rs:292-305`)
  - one settlement step per tick (`mod.rs:361-384`)

## Defended mechanisms

- The persistent `RecoveryTree` with pruning (`recovery.rs:51-102`, `173`).
  - Argument: per-tick scan cost must not grow with the dispute's age or with
    adversary-created tournaments, because the scan runs before the wave
    (`recovery.rs:21-27`).
  - Cost: about 50 lines.
  - Its loss costs one walk (`recovery.rs:51-52`). Restart rebuilds the full
    tree before any pruning, since the walk runs before dispositions are read
    (`recovery.rs:126`, `128-161`).
  - The only correctness premise is a contract property: a tournament that is
    recovered, foreign-won or winnerless has finished and creates no child.
    That is plausible, since a child needs an unresolved match.
  - Pruning relies on that premise only to skip walks. If the premise broke,
    the persistent tree would miss a later child's bond while a restart would
    find it. So it is a cache with one premise, not correctness machinery.
  - Test: `recovery.rs:515-547`.
- Two foreclosure reads, latest then finalized (`mod.rs:212-218`,
  `315-324`). A latest foreclosure suppresses settlement calls, which costs
  nothing if reorged. Only a finalized one stops the node. Test:
  `harness/tests.rs:147`.
- `track_planned` keyed by verb, target and calldata hash
  (`mod.rs:643-679`).
  - Planning reads latest and drops a landed call, so a call planned for G
    has not landed. The key separates one step from the next of the same
    verb.
  - Cost: about 40 lines. It replaces per-call receipt tracking, which keeps
    the lane stateless (`node-architecture.md:721`).
- One settlement step per tick (`mod.rs:361-384`): the next step never queues
  behind a stale earlier one.
- The `settled` guard compares ingestion with this tick's finalized sample
  (`mod.rs:192-196`), not with ingestion alone. A lagging provider cannot let
  a refund classification retire an epoch at a head that has not seen its
  settlement.

## Candidate changes

1. Tie the Hero to its epoch: store `Option<(u64, Hero)>` or expose
   `Hero::epoch()`, and assert equality with the cursor epoch at
   `mod.rs:568`.
   - Premise: invariant 3's first half is a convention.
   - Buys a tripwire for the storage GC argument
     (`node-architecture.md:438-452`) at about 3 lines.
   - Costs nothing at runtime. It could break no invariant.
   - Reopen if: the cursor gains a second writer.
   - Confidence: medium. The value is documentation-by-code; today's code
     cannot violate it.
2. Bound a settled epoch's recovery walk at the next seal's block: use
   `min(finalized, next.block_created_number)` as `to` in `walk_to`
   (`recovery.rs:126`).
   - Premise: every child is created before its root finishes, and the root
     finishes before acceptance, which emits the next `EpochSealed`
     (`IDaveConsensus.sol:332-334`).
   - Buys: a fresh directory replaying many epochs, or a restart deep in
     history, walks `[created, settled]` instead of
     `[created, finalized_now]` per generation. Today each historical epoch's
     walk spans the whole chain after it (`recovery.rs:76-101`), and
     `logs_bisecting` multiplies calls on range-capped providers.
   - Costs: one parameter, and a reliance on the same contract property as
     pruning.
   - Reopen if: replay cost is measured as negligible.
   - Confidence: medium on correctness, low on need (unmeasured).
3. After `Lost(Root { final_state })` with `final_state == ours`, allow
   `plan_stage_tournament_result` with the commitment assert relaxed to the
   final state.
   - Premise: the proof validates against the winner's final state only, so
     this node's stored proof stages it.
   - Buys liveness outside the trust model (the honest commitment lost, and
     the winner does not stage).
   - Costs: it weakens the settle assert's precondition from "our own win" to
     "our final state", and it adds a branch to a security-sensitive path.
     Inside the trust model the honest commitment wins the root
     (`epoch-lifecycle.md:137-140`), so the case does not arise.
   - Not worth it: out-of-model liveness, and anyone (the operator included)
     can stage by hand. Recorded decision (`mod.rs:612-618`), not reopened.
4. Share the `NewInnerTournament` provenance walk between recovery and
   `tournament/reader.rs`.
   - Not worth it: the two have different retention (resolved children kept
     versus dropped), different event sets, and recovery must run without a
     Hero. The shared part is about 15 lines.
5. Give each stall cause its own `Persistence`.
   - Not worth it: one epoch-level "has not advanced" clock is the
     operator's question, and a shared clock pages no later than separate
     ones.
6. Fold `completion.rs` into another storage role file.
   - Not worth it: the per-role writer layout is the storage module's
     convention (`node-architecture.md:287-294`), and 55 lines cost nothing.

## Not verified

- The "scratch test" in which a second node with another key stages and
  accepts another node's win: I found none in `src/harness/tests.rs` (test
  list at lines 147-1059) or elsewhere in `src/`. The claim rests on
  `planner.rs:113` (win by commitment) and the signer-free settlement guards
  (`mod.rs:456-552`). I did not run any harness.
- `Fatal::of` recognizing the `ensure!`-wrapped terminal from
  `hero/actor.rs:290-300`: read, not traced through `fatal.rs`.
- The contract claim that a finished tournament creates no child (premise of
  the recovery pruning and candidate 2): I did not read `Tournament.sol`.
- `HeroContext::assemble` (`hero/context.rs`) beyond the `machine_work` call
  site; `chain.rs` `logs_bisecting` internals.

## Answers to the task's specific questions

1. One tick (`execution_loop` `mod.rs:105-130` -> `tick` `mod.rs:132-185` ->
   `plan_tick` `mod.rs:187-335`):
   1. Read the cursor epoch e, or idle if its seal has not been ingested
      (`mod.rs:188-190`, `queries.rs:33-45`).
   2. Sample the finalized head (`mod.rs:191`). Compute `settled` from
      storage plus that head (`mod.rs:194-196`).
   3. If not settled and the settlement row exists (`mod.rs:203-204`): build
      the Hero if absent (`mod.rs:568-578`) and tick it. It samples latest
      itself and may run machine work inline (`actor.rs:180-281`). Push its
      request (`mod.rs:209`).
   4. If the result is Some: read `isForeclosed` at the Hero's head
      (`mod.rs:212-218`).
   5. If not foreclosed and the result is `Won` or `Lost(Root)`: plan at most
      one settlement step, with every view pinned to the Hero's head
      (`mod.rs:223-257`). Push it.
   6. If there is no settlement row, log a wait (`mod.rs:268-289`).
   7. `plan_recovery` at the finalized head sampled in step 2: walk new
      finalized blocks, read every open tournament's `bondRecovery` at the
      finalized hash, then read candidates at latest to suppress mined ones
      (`recovery.rs:108-198`). Push the recoveries (`mod.rs:304`).
   8. If foreclosed at latest, recovery is complete, and foreclosure is
      finalized: exit 30 (`mod.rs:317-329`).
   9. Back in `tick`: if `settled && complete`, drop the Hero and advance the
      cursor (`mod.rs:142-153`). Otherwise submit the wave
      (`mod.rs:154-156`) and update call paging (`mod.rs:157-176`).
   10. On `done`, loop without sleeping (`mod.rs:114-116`).
2. See invariant 3.
3. Settlement planning:
   - Sentry claim:
     - Preconditions: the signer is a sentry (`mod.rs:396-409`); the view's
       epoch is e (`417`); the result is not already staged past its period
       (`420-425`); the sentry has not claimed (`427-439`).
     - Fields: epoch from the head view (equal to e); the hash from the stored
       `final_state` (`441-444`).
     - No asserts.
     - Planned on `Won` (first in `plan_settlement`, `mod.rs:370-375`) or
       `Lost(Root)` (`mod.rs:240-246`).
   - Stage:
     - Preconditions: epoch is e, and `isFinished && !isTournamentFailed &&
       !isTournamentResultStaged` (`mod.rs:462-476`).
     - Asserts: `mod.rs:478-487`. A non-settling state is held with an error
       (`491-497`).
     - Fields: epoch from the view, and the proof from the stored row
       (`502-507`).
   - Accept:
     - Preconditions: epoch is e and the result is staged (`524-530`).
     - Asserts: `532-541`.
     - Waits for unanimity or the period (`542-546`). Field: the view's epoch
       (`549`).
   - Stage and accept are planned only on `Won`, decided by commitment
     (`planner.rs:113`). So another key with the same commitment stages and
     accepts; the views carry no signer.
4. Foreclosure: read only once the dispute has a result (`mod.rs:212`). Latest
   suppresses settlement (`mod.rs:223`). It never gates the Hero or recovery.
   Exit-30 sources reachable from this tick:
   - (a) Finalized foreclosure with recovery complete (`mod.rs:317-329`).
   - (b) The next epoch's root starts from a state this node did not compute
     (`hero/actor.rs:285-300`). That is reached only after the previous
     epoch's refunds and vote, since its Hero is built only after the cursor
     advanced.
5. Recovery:
   - The tree holds `epoch_number`, `next_block`, and the open tournaments
     (`recovery.rs:54-61`).
   - Per tick: logs over `[next_block, finalized]` per generation of open
     tournaments, one finalized `bondRecovery` per open tournament
     (concurrency 16), and one latest `bondRecovery` per candidate.
   - Dispositions: RECOVERABLE-ours is a candidate and stays open; foreign
     RECOVERABLE, RECOVERED and NO_WINNER close it; RUNNING and unknown stay
     open (`recovery.rs:144-160`).
   - Completion is held by any open entry.
   - Restart: one walk from root creation. It is a cache whose loss costs one
     walk, with the single contract premise noted under Defended mechanisms.
6. Paging:
   - Calls are keyed by `call_key` (`mod.rs:643-646`) and timed by
     `track_planned` against `PAGE_AFTER` (`escalation.rs:22`,
     `mod.rs:656-679`). They are cleared when no wave is sent
     (`mod.rs:178-180`).
   - The epoch stall goes through `stalled()` (`mod.rs:340-349`). It is
     cleared in the loop (`mod.rs:110-112`).
7. See "What it knows about its neighbours".
8. Settled historical epochs: no Hero and no settlement row needed
   (`mod.rs:203`). Recovery runs alone, and done is `settled && complete`
   (`mod.rs:333`). Catch-up runs without sleep. Test: `mod.rs:916-929`.
9. Inline machine work: `hero/actor.rs:251` and `hero/context.rs:90` call
   `machine_work` (`hero/mod.rs:22-28`). The argument for safety is
   `docs/node-architecture.md:701-719`:
   - The Hero has a single path, and a cold build starts only after the seal
     that created its level.
   - Settlement waits for a root winner.
   - `tryRecoveringBond` has no deadline.
   - The tick re-observes once after a build (`actor.rs:188-200`).
10. On-chain signals per epoch:
    - DaveConsensus:
      - `EpochSealed(e, ..., tournament)` marks the start; the
        `EpochSealed(e+1)` emitted by `acceptStagedTournamentResult` marks
        settlement (`IDaveConsensus.sol:75-82`, `332-335`).
      - `canStageTournamentResult()` (`isFinished`, `isTournamentFailed`,
        `isTournamentResultStaged`, `epochNumber`) shows a finished root not
        yet staged (`IDaveConsensus.sol:278-288`).
      - `EpochStaged` and `getCurrentSealedEpoch().stagingBlockNumber` give
        the staging time (`IDaveConsensus.sol:100-104`, `250-262`).
      - `canAcceptStagedTournamentResult()` (staged, all sentries agree,
        period over) shows a staged result not yet accepted
        (`IDaveConsensus.sol:320-330`).
      - `SentryClaim` events, `hasSentryClaimedInEpoch` and
        `getSentryClaimCount` show sentry votes (`IDaveConsensus.sol:89-94`,
        `213-221`).
    - Application: `isForeclosed()`.
    - Tournament, for refunds:
      - `tournamentStanding()` (`ITournament.sol:914`)
      - `bondRecovery()` (`ITournament.sol:935-938`)
      - `BondRecovered` events (`ITournament.sol:389`)
      - `NewInnerTournament` (`ITournament.sol:412`) to enumerate the tree.
