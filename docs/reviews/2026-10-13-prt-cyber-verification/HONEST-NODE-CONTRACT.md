# The honest node's composition contract

What the PRT contracts require of an honest validator, written for the node
campaign. Every progress action is permissionless and a child commitment is
classified by final state, so the honest node must do things the protocol
docs do not all state. Each item gives the requirement, the consequence if
unmet, and the contract line that makes it so. Line numbers are
`prt/contracts/src` at the 2026-10-13 campaign tree; re-check them.
Executable evidence: `test/properties/HonestNodeObligations.t.sol` (named in brackets).
Node pointers (`hero/planner.rs` and friends) are leads to verify, not claims.

Time is `block.number`; every clock and window below is in blocks. Every
expiry is inclusive: an action must be included strictly before the instant
named.

## Identity and joining

1. Identify the local commitment by its root, never by claimer. A root joins
   once per tournament (`Clock.sol:130`, `ClockAlreadyInitialized`), the
   first joiner is the claimer (`Tournament.sol:241`), and an elimination or a
   recovery zeroes the claimer (`Tournament.sol:1230-1238`, `:447`). Unmet: the
   node misses its own commitment and either stops defending or keeps
   re-joining. [testContractHonestJoinRevertsButDefenseWins]
2. Defend the correct commitment even when another address joined it first.
   The honest join reverts, but every progress verb is open to anyone who
   knows the tree; only the terminal payment goes to the first claimer
   (`Tournament.sol:497`). Unmet: an adversary that front-runs the join and
   then stays silent wins by the honest commitment's timeout.
3. Start the child build at the `NewInnerTournament` event, whoever sealed,
   and whether or not the local root is already joined there. The child
   starts at the seal block (`MultiLevelTournamentFactory.sol:172`); an
   adversary can join the honest child root and pair it at once, so its clock
   may run before the honest build ends. That costs no more than the honest
   node's own join at `T + G` would (`Clock.sol:131`, `:159`). [testRefutedPreJoinBeforeBuildDrainsHonestChildClock]
4. Join every child created from a match the local commitment is in, within
   `T + G` of the seal. The clock is initialized at
   `envelope - (now - startInstant)` (`Clock.sol:131`, `Tournament.sol:235`);
   joins stop at `startInstant + allowance` inclusive (`Tournament.sol:221`,
   `:1050-1056`). Lateness beyond `T + G` is drawn from `C`; a missed closure
   loses the parent match if the other class joined, or eliminates both
   parents if nobody did.
5. Join with the child's own bond, at least `bondValue()` of that clone
   (`Tournament.sol:222`), as published in `NewInnerTournament.bondValue`
   (`ITournament.sol:399-408`). Any excess is retained and not refunded.
6. Join with the commitment built from the child's descriptor and sealed
   agree state: `initialHash` is the agree state and `baseCycle` the parent's
   divergence cycle (`Tournament.sol:712-722`), and the last leaf must be the
   contested final state of the local side (`Tournament.sol:166-187`,
   `:1249-1264`). Unmet: `InvalidContestedFinalState`, or a commitment that
   loses every bisection.
7. Make the claimer address able to receive ETH within the payment gas
   (`Bond.PAYMENT_CALL_GAS`, `Tournament.sol:1312-1326`). Unmet: refunds fail
   silently and terminal recovery returns false forever, leaving the pool
   locked (`Tournament.sol:433-435`).

## Pairing and matches

8. Watch a dangling candidate until its tournament closes. A join in the
   last open block pairs it as the elder and starts its clock
   (`Tournament.sol:1190-1202`, only commitment one runs); progress verbs are
   gated on finished, not closed (`Tournament.sol:254`, `:1059-1065`).
   [testContractLateJoinStartsDanglingHonestClock]
9. Refold after every own win. A timeout win, a leaf proof and a child
   propagation re-pair the winner inside the same call (`Tournament.sol:325`,
   `:625`, `:787`), so the local commitment may be commitment two of a new
   match created in that transaction, with the dangling elder's clock
   running.
10. Take the match id from `MatchCreated` as `(elder, newcomer)` and hash it
    as `keccak256(abi.encode(id))` (`Match.sol:36-38`, `:82`); never sort the
    pair. Side and turn follow from it: commitment one responds first and
    the responder flips on every advance (`Match.sol:211-223`).
11. Respond within `G` of the response becoming due. A response is
    discounted by `max(elapsed - G, 0)` and rejected at `elapsed >= balance`
    (`Clock.sol:148-161`). The reveal is fixed by the committed tree
    (`Match.sol:103-125`), so a third party can respond for the honest side
    only with the same nodes, and that only helps.
12. At height one, seal with the local tree's agree-state proof: against
    `initialHash` at position zero, otherwise the leaf before the divergence
    of the final revealer (`Match.sol:157-178`, `:290-308`). In a non-leaf
    tournament the seal creates the child through the factory
    (`Tournament.sol:673-728`); budget its gas.
13. Treat a sealed non-leaf match as having no local timeout: both clocks are
    paused and the classifier returns `NONE` (`MatchClocks.sol:160-168`,
    `Tournament.sol:952-958`). The obligation moves wholly into the child.

## Timeouts and the leaf race

14. When the opponent expires during bisection, claim the timeout within `G`
    of its deadline. The paused winner is charged the overdue beyond `G`
    (`MatchClocks.sol:236-238`, `Clock.sol:170-183`); from
    `deadline + own remainder` the match is `ELIMINATE_BOTH` and anyone may
    delete both (`MatchClocks.sol:240-249`, `Tournament.sol:369-397`).
    [testContractTimeoutClaimWindow]
15. In a sealed leaf, classify before proving: the proof is accepted only
    while the classification is `NONE`, strictly before the earlier deadline
    (`Tournament.sol:594-598`). Once the opponent expired, claim the timeout
    instead; the proof reverts (CF-01, accepted). Once both expired, both are
    eliminated. The planner does this (`hero/planner.rs`, `plan_engagement`).
16. Land the leaf proof plus its fallback timeout claim within `G` of the
    seal. The adversary may seal its own leaf turn when its clock is nearly
    spent, leaving the honest proof a window of a few blocks
    (`MatchClocks.sol:146-155`, `:63-79`); beyond `G` each occurrence costs
    `C` (r19-honest-survival.md, CF-01).
17. Prove for the local side by passing the local root's children: the side
    is chosen by which root the children join to (`Tournament.sol:616-660`).

## Recursion

18. Propagate a child win as soon as the child is finished, which may be its
    closure rather than the last deletion: `resultAt` is the later of the
    two (`Tournament.sol:1085-1092`). The carried clock decays from
    `resultAt` (`Tournament.sol:1368-1371`) and the refill restores at most
    `T + 2G` within the envelope (`MatchClocks.sol:184-194`).
19. Propagate strictly before `resultAt + pausedAllowance`. At that instant
    the child is `ELIMINABLE`, propagation reverts
    (`Tournament.sol:749-752`, `:1097-1103`), and anyone's
    `eliminateInnerTournament` deletes both parent sides, the honest one
    included (`Tournament.sol:829-834`). [testContractPropagationDeadlineIsHard]
20. Propagate a win by any entrant of the local class, not only by the local
    child commitment. The child maps its winner to a parent side by final
    state (`Tournament.sol:1161-1171`, `:1363-1365`) and the parent checks
    only that side's children (`Tournament.sol:758-771`). Pass the parent
    commitment's children, not the child winner's.
    [testContractSameClassDistinctRootChildWinSavesHonestParent]
21. Do not treat the loss or absence of the local child commitment as
    terminal for the parent: a same-class distinct root may still win the
    child. Lead for the node: the planner checks the child's standing before
    the local standing, so it propagates such a win, but while the child runs
    it reports `Lost` and the actor then skips cleanup (`hero/actor.rs`,
    the gc branch guarded by `TournamentResult::Running`).
22. Expect the returned clock to be the shared envelope cap, not the local
    snapshot: `min(carried + T + 2G, max(r1, r2))` with the parent's `T` and
    `G` (`Tournament.sol:775-785`). A same-class winner carries its own
    clock, which may be small.
23. Keep each parent clock above what the descendants need at every seal.
    The child envelope is `max(r1, r2)` after the seal discount
    (`MatchClocks.sol:160-168`); if the honest remainder cannot cover a build,
    a join and the child's own play, the honest side survives only if the
    opponent's remainder is larger. Responding within `G` everywhere is what
    keeps the root formula's reserve.

## Finish, cleanup and money

24. Drive the root to finish, since it finishes only with no live matches
    (`Tournament.sol:1059-1065`). Sybil-versus-Sybil matches need
    `eliminateMatchByTimeout` at `eliminableAt` and children need
    `eliminateInnerTournament` once `ELIMINABLE`; a third party cannot win a
    Sybil match by timeout without the survivor's children
    (`Tournament.sol:317-319`), so cleanup waits for double elimination.
25. Recover bonds only after finish, for every tournament where the local
    address is claimer, the children included. Recovery has no time arm and
    is independent of propagation: `innerResult` ignores claimers
    (`Tournament.sol:414-452`, `:1332-1372`). It also pays an expired child
    winner (phase 2 NatSpec lead).
26. Treat a reverted own action as possibly done by someone else and re-read
    state. Duplicates revert on phase or node checks (`Match.sol:263-285`),
    timeout verbs on the classifier (`Tournament.sol:365`, `:395`), joins on
    `ClockAlreadyInitialized`, and finished tournaments on
    `TournamentIsFinished`.
27. Submit through a revert-protecting endpoint where possible: a reverted
    transaction gets no refund, since the refund is paid only at the end of a
    successful body (`Tournament.sol:125-129`, `:1288-1308`).
28. Settle by final state. A root winner with the correct final state but a
    different root is a correct outcome (`Tournament.sol:1001-1004`); the
    planner reports it as `Lost` (`hero/planner.rs`, `RootWinner`), which is
    a log, not a safety issue.

## Observation

29. Trust `StandingChanged` and every other event only from tournaments
    reached through the consensus's `EpochSealed` and parents'
    `NewInnerTournament` (`ITournament.sol:430-432`). The factory creates
    orphans for anyone; a parent rejects them (`Tournament.sol:742-746`: an
    unrecorded child resolves to an absent match).
30. Keep `LeafMatchSealed` as the durable divergence record: match storage is
    zeroed on deletion (`Tournament.sol:1240`, `ITournament.sol:316-318`).
31. Read deadlines from the events and views, which share the mutators'
    arithmetic (`MatchClocks.sol:38-79`, `Tournament.sol:1097-1118`), and
    take the latest event per match or tournament in log order: each new
    schedule supersedes the previous one.
