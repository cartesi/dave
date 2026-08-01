// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {SmallTwoLevelClaims} from "../fixtures/SmallTwoLevelClaims.sol";
import {
    SmallTwoLevelGeometry,
    SmallTwoLevelTournamentFactory
} from "../fixtures/SmallTwoLevelTournament.sol";

/// @dev A production-path population trace with two concurrently active child
/// tournaments. The synthetic commitments are timeout witnesses, not execution
/// traces; state-transition correctness is outside this test's scope.
contract ConcurrentRecursivePopulationTest is Test {
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Duration;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant RESPONSE_BUDGET = 5;
    uint64 internal constant MAX_ALLOWANCE = 200;
    uint256 internal constant CONTESTED_SEGMENT = 2;

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    address internal constant CLAIMER_THREE = address(0xca11);
    address internal constant CLAIMER_FOUR = address(0xd00d);

    SmallTwoLevelTournamentFactory internal immutable FACTORY;

    InspectableTournament internal parent;
    InspectableTournament internal childOne;
    InspectableTournament internal childTwo;

    Tree.Node[4] internal parentRoots;
    Tree.Node[4] internal childOneRoots;
    Tree.Node[4] internal childTwoRoots;

    Match.Id internal parentMatchOne;
    Match.Id internal parentMatchTwo;

    constructor() {
        FACTORY = new SmallTwoLevelTournamentFactory(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
    }

    function setUp() public {
        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);
        for (uint8 i; i < 4; ++i) {
            vm.deal(_claimer(i), 100 ether);
        }

        parent = InspectableTournament(
            address(
                FACTORY.instantiate(
                    SmallTwoLevelClaims.initialState(),
                    IDataProvider(address(0))
                )
            )
        );

        for (uint8 claim; claim < SmallTwoLevelClaims.CLAIM_COUNT; ++claim) {
            parentRoots[claim] = _join(
                parent, SmallTwoLevelClaims.rootTree(claim), _claimer(claim)
            );
        }
        parentMatchOne = Match.Id(parentRoots[0], parentRoots[1]);
        parentMatchTwo = Match.Id(parentRoots[2], parentRoots[3]);
    }

    function testConcurrentChildrenReduceRecursivePopulation() public {
        _assertInitialParentPopulation();

        childOne = _sealParentMatch(
            parentMatchOne,
            SmallTwoLevelClaims.CLAIM_ONE,
            SmallTwoLevelClaims.CLAIM_TWO
        );
        childTwo = _sealParentMatch(
            parentMatchTwo,
            SmallTwoLevelClaims.CLAIM_THREE,
            SmallTwoLevelClaims.CLAIM_FOUR
        );

        assertNotEq(address(childOne), address(childTwo));
        _assertDelegatedParentPopulation();
        _assertChildArguments(
            childOne,
            parentMatchOne,
            SmallTwoLevelClaims.CLAIM_ONE,
            SmallTwoLevelClaims.CLAIM_TWO
        );
        _assertChildArguments(
            childTwo,
            parentMatchTwo,
            SmallTwoLevelClaims.CLAIM_THREE,
            SmallTwoLevelClaims.CLAIM_FOUR
        );
        assertFalse(parent.isClosed());

        _populateChild(childOne, SmallTwoLevelClaims.CLAIM_ONE, childOneRoots);
        _populateChild(childTwo, SmallTwoLevelClaims.CLAIM_THREE, childTwoRoots);
        _assertFreshChildPopulation(childOne, childOneRoots);
        _assertFreshChildPopulation(childTwo, childTwoRoots);

        uint256 firstDeadline = _tournamentDeadline(childOne);
        assertEq(firstDeadline, START_BLOCK + MAX_ALLOWANCE);
        assertEq(_tournamentDeadline(childTwo), firstDeadline);
        vm.roll(firstDeadline);

        _resolveFirstChildWave(
            childOne, SmallTwoLevelClaims.CLAIM_ONE, childOneRoots
        );
        _resolveFirstChildWave(
            childTwo, SmallTwoLevelClaims.CLAIM_THREE, childTwoRoots
        );
        _assertReducedChildPopulation(childOne, childOneRoots);
        _assertReducedChildPopulation(childTwo, childTwoRoots);
        _assertDelegatedParentPopulation();
        assertTrue(parent.isClosed());
        assertFalse(parent.isFinished());

        vm.roll(firstDeadline + MAX_ALLOWANCE);
        _resolveSecondChildWave(
            childOne, SmallTwoLevelClaims.CLAIM_ONE, childOneRoots
        );
        _assertFinishedChild(childOne, parentRoots[0], childOneRoots[3]);

        _propagateChild(childOne, SmallTwoLevelClaims.CLAIM_ONE);
        _assertParentPopulationThree();

        _resolveSecondChildWave(
            childTwo, SmallTwoLevelClaims.CLAIM_THREE, childTwoRoots
        );
        _assertFinishedChild(childTwo, parentRoots[2], childTwoRoots[3]);
        _propagateChild(childTwo, SmallTwoLevelClaims.CLAIM_THREE);
        Match.Id memory finalMatch = Match.Id(parentRoots[0], parentRoots[2]);
        _assertParentPopulationTwo(finalMatch);

        vm.roll(block.number + MAX_ALLOWANCE);
        SmallFullTree.Data memory winner =
            SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_THREE);
        _winSecondAtDeadline(parent, finalMatch, winner);

        _assertFinalParentPopulation(winner, finalMatch);
    }

    function _assertInitialParentPopulation() private view {
        _assertTopology(parent, Tree.ZERO_NODE, 2, 4, 0);
        _assertClock(parent, parentRoots[0], true, MAX_ALLOWANCE, START_BLOCK);
        _assertClock(parent, parentRoots[1], false, MAX_ALLOWANCE, 0);
        _assertClock(parent, parentRoots[2], true, MAX_ALLOWANCE, START_BLOCK);
        _assertClock(parent, parentRoots[3], false, MAX_ALLOWANCE, 0);

        assertTrue(parent.getMatch(parentMatchOne.hashFromId()).exists());
        assertTrue(parent.getMatch(parentMatchTwo.hashFromId()).exists());
        _assertCounters(parent, 4, 2, 0, 0, 0);
    }

    function _assertDelegatedParentPopulation() private view {
        _assertTopology(parent, Tree.ZERO_NODE, 2, 4, 0);
        for (uint8 i; i < 4; ++i) {
            _assertClock(parent, parentRoots[i], false, MAX_ALLOWANCE, 0);
        }

        _assertSealedMatch(parentMatchOne);
        _assertSealedMatch(parentMatchTwo);
        _assertOrigin(childOne, parentMatchOne);
        _assertOrigin(childTwo, parentMatchTwo);

        // Each sealed parent match contributes one linked child resolution
        // obligation in place of one locally timed match.
        _assertCounters(parent, 4, 2, 2, 0, 2);
    }

    function _assertChildArguments(
        InspectableTournament tournament,
        Match.Id memory origin,
        uint8 claimOne,
        uint8 claimTwo
    ) private view {
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        SmallFullTree.Data memory parentOne =
            SmallTwoLevelClaims.rootTree(claimOne);
        SmallFullTree.Data memory parentTwo =
            SmallTwoLevelClaims.rootTree(claimTwo);
        Machine.Hash initialOne =
            SmallTwoLevelClaims.childInitialState(claimOne, CONTESTED_SEGMENT);
        Machine.Hash initialTwo =
            SmallTwoLevelClaims.childInitialState(claimTwo, CONTESTED_SEGMENT);

        assertEq(args.level, 1);
        assertEq(args.levels, SmallTwoLevelGeometry.LEVELS);
        assertEq(args.commitmentArgs.height, SmallTwoLevelGeometry.LEAF_HEIGHT);
        assertEq(
            args.commitmentArgs.log2step, SmallTwoLevelGeometry.LEAF_LOG2_STEP
        );
        assertEq(Time.Instant.unwrap(args.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(args.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(args.responseBudget), RESPONSE_BUDGET);
        assertTrue(args.commitmentArgs.initialHash.eq(initialOne));
        assertTrue(initialOne.eq(initialTwo));
        _assertNodeEq(
            args.nestedDispute.contestedCommitmentOne, parentRoots[claimOne]
        );
        _assertNodeEq(
            args.nestedDispute.contestedCommitmentTwo, parentRoots[claimTwo]
        );
        assertTrue(
            args.nestedDispute.contestedFinalStateOne
                .eq(parentOne.leaf(CONTESTED_SEGMENT).toMachineHash())
        );
        assertTrue(
            args.nestedDispute.contestedFinalStateTwo
                .eq(parentTwo.leaf(CONTESTED_SEGMENT).toMachineHash())
        );
        assertEq(
            args.commitmentArgs.startCycle,
            SmallTwoLevelClaims.childStartCycle(CONTESTED_SEGMENT)
        );
        _assertOrigin(tournament, origin);
    }

    function _assertFreshChildPopulation(
        InspectableTournament tournament,
        Tree.Node[4] storage roots
    ) private view {
        _assertTopology(tournament, Tree.ZERO_NODE, 2, 4, 0);
        _assertClock(tournament, roots[0], true, MAX_ALLOWANCE, START_BLOCK);
        _assertClock(tournament, roots[1], false, MAX_ALLOWANCE, 0);
        _assertClock(tournament, roots[2], true, MAX_ALLOWANCE, START_BLOCK);
        _assertClock(tournament, roots[3], false, MAX_ALLOWANCE, 0);
        _assertCounters(tournament, 4, 2, 0, 0, 0);
        assertFalse(tournament.isClosed());
    }

    function _assertReducedChildPopulation(
        InspectableTournament tournament,
        Tree.Node[4] storage roots
    ) private view {
        Match.Id memory survivorMatch = Match.Id(roots[1], roots[3]);
        _assertTopology(tournament, Tree.ZERO_NODE, 1, 2, block.number);
        assertTrue(tournament.getMatch(survivorMatch.hashFromId()).exists());
        _assertClock(tournament, roots[1], true, MAX_ALLOWANCE, block.number);
        _assertClock(tournament, roots[3], false, MAX_ALLOWANCE, 0);
        _assertCounters(tournament, 4, 3, 0, 2, 0);
        assertTrue(tournament.isClosed());
        assertFalse(tournament.isFinished());
    }

    function _assertFinishedChild(
        InspectableTournament tournament,
        Tree.Node expectedParentWinner,
        Tree.Node expectedChildWinner
    ) private view {
        _assertTopology(tournament, expectedChildWinner, 0, 1, block.number);
        _assertClock(tournament, expectedChildWinner, false, MAX_ALLOWANCE, 0);
        _assertCounters(tournament, 4, 3, 0, 3, 0);
        assertTrue(tournament.isClosed());
        assertTrue(tournament.isFinished());
        assertFalse(tournament.canBeEliminated());

        (bool timeKnown, Time.Instant finishedAt) = tournament.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);

        (
            bool finished,
            Tree.Node parentWinner,
            Tree.Node childWinner,
            Clock.State memory returnedClock
        ) = tournament.innerTournamentWinner();
        assertTrue(finished);
        _assertNodeEq(parentWinner, expectedParentWinner);
        _assertNodeEq(childWinner, expectedChildWinner);
        assertFalse(returnedClock.isRunning());
        assertEq(Time.Duration.unwrap(returnedClock.allowance), MAX_ALLOWANCE);
    }

    function _assertParentPopulationThree() private view {
        _assertTopology(parent, parentRoots[0], 1, 3, block.number);
        assertFalse(parent.getMatch(parentMatchOne.hashFromId()).exists());
        _assertSealedMatch(parentMatchTwo);
        _assertClock(parent, parentRoots[0], false, MAX_ALLOWANCE, 0);
        _assertClock(parent, parentRoots[2], false, MAX_ALLOWANCE, 0);
        _assertClock(parent, parentRoots[3], false, MAX_ALLOWANCE, 0);
        _assertClearedOrigin(childOne);
        _assertOrigin(childTwo, parentMatchTwo);
        _assertPendingSecondChildWave(childTwo, childTwoRoots);

        // The remaining parent pair is delegated and the odd commitment is
        // dangling, so the linked child carries the one resolution obligation.
        _assertCounters(parent, 4, 2, 2, 1, 2);
        assertTrue(parent.isClosed());
        assertFalse(parent.isFinished());
    }

    function _assertPendingSecondChildWave(
        InspectableTournament tournament,
        Tree.Node[4] storage roots
    ) private view {
        Match.Id memory survivorMatch = Match.Id(roots[1], roots[3]);
        _assertTopology(
            tournament, Tree.ZERO_NODE, 1, 2, START_BLOCK + MAX_ALLOWANCE
        );
        assertTrue(tournament.getMatch(survivorMatch.hashFromId()).exists());
        assertTrue(tournament.canWinMatchByTimeout(survivorMatch));
        _assertClock(
            tournament,
            roots[1],
            true,
            MAX_ALLOWANCE,
            START_BLOCK + MAX_ALLOWANCE
        );
        _assertClock(tournament, roots[3], false, MAX_ALLOWANCE, 0);
        assertTrue(tournament.isClosed());
        assertFalse(tournament.isFinished());
    }

    function _assertParentPopulationTwo(Match.Id memory finalMatch)
        private
        view
    {
        _assertTopology(parent, Tree.ZERO_NODE, 1, 2, block.number);
        assertFalse(parent.getMatch(parentMatchTwo.hashFromId()).exists());
        assertTrue(parent.getMatch(finalMatch.hashFromId()).exists());
        _assertClock(parent, parentRoots[0], true, MAX_ALLOWANCE, block.number);
        _assertClock(parent, parentRoots[2], false, MAX_ALLOWANCE, 0);
        _assertClearedOrigin(childOne);
        _assertClearedOrigin(childTwo);

        // Both child winners arrived in the same block and immediately formed
        // the one locally active match required by floor(2 / 2).
        _assertCounters(parent, 4, 3, 2, 2, 2);
        assertTrue(parent.isClosed());
        assertFalse(parent.isFinished());
    }

    function _assertFinalParentPopulation(
        SmallFullTree.Data memory winner,
        Match.Id memory finalMatch
    ) private view {
        assertFalse(parent.getMatch(finalMatch.hashFromId()).exists());
        _assertTopology(parent, winner.root(), 0, 1, block.number);
        _assertClock(parent, winner.root(), false, MAX_ALLOWANCE, 0);
        assertTrue(parent.isClosed());
        assertTrue(parent.isFinished());
        _assertCounters(parent, 4, 3, 2, 3, 2);

        (bool timeKnown, Time.Instant finishedAt) = parent.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);

        (bool finished, Tree.Node result, Machine.Hash finalState) =
            parent.arbitrationResult();
        assertTrue(finished);
        _assertNodeEq(result, winner.root());
        assertTrue(finalState.eq(winner.finalState()));
        assertEq(parent.observedClaimer(winner.root()), CLAIMER_THREE);
        assertEq(parent.observedClaimer(parentRoots[0]), address(0));
        assertEq(parent.observedClaimer(parentRoots[1]), address(0));
        assertEq(parent.observedClaimer(parentRoots[3]), address(0));
    }

    function _sealParentMatch(
        Match.Id memory matchId,
        uint8 claimOne,
        uint8 claimTwo
    ) private returns (InspectableTournament child) {
        SmallFullTree.Data memory one = SmallTwoLevelClaims.rootTree(claimOne);
        SmallFullTree.Data memory two = SmallTwoLevelClaims.rootTree(claimTwo);

        (Tree.Node left, Tree.Node right) =
            one.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) = one.children(1, 1);
        parent.advanceMatch(matchId, left, right, nextLeft, nextRight);

        (left, right) = two.children(1, 1);
        vm.recordLogs();
        parent.sealInnerMatchAndCreateInnerTournament(
            matchId,
            left,
            right,
            two.leaf(CONTESTED_SEGMENT - 1).toMachineHash(),
            two.proof(CONTESTED_SEGMENT - 1)
        );
        child = _recordedChild(matchId);

        Match.State memory state = parent.getMatch(matchId.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        assertEq(state.runningLeafPosition, CONTESTED_SEGMENT);
        assertEq(
            parent.getMatchCycle(matchId.hashFromId()),
            SmallTwoLevelClaims.childStartCycle(CONTESTED_SEGMENT)
        );
    }

    function _recordedChild(Match.Id memory origin)
        private
        returns (InspectableTournament child)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(parent) || entry.topics.length != 3
                    || entry.topics[0]
                        != ITournament.NewInnerTournament.selector
            ) {
                continue;
            }

            ++count;
            assertEq(entry.topics[1], Match.IdHash.unwrap(origin.hashFromId()));
            assertEq(entry.data.length, 0);
            child = InspectableTournament(
                address(uint160(uint256(entry.topics[2])))
            );
        }
        assertEq(count, 1);
        assertNotEq(address(child), address(0));
    }

    function _populateChild(
        InspectableTournament tournament,
        uint8 claim,
        Tree.Node[4] storage roots
    ) private {
        for (uint8 variant; variant < 4; ++variant) {
            roots[variant] = _join(
                tournament,
                SmallTwoLevelClaims.childTreeVariant(
                    claim, CONTESTED_SEGMENT, variant
                ),
                _claimer(variant)
            );
        }
    }

    function _resolveFirstChildWave(
        InspectableTournament tournament,
        uint8 claim,
        Tree.Node[4] storage roots
    ) private {
        Match.Id memory firstMatch = Match.Id(roots[0], roots[1]);
        _winSecondAtDeadline(
            tournament,
            firstMatch,
            SmallTwoLevelClaims.childTreeVariant(claim, CONTESTED_SEGMENT, 1)
        );
        assertFalse(tournament.getMatch(firstMatch.hashFromId()).exists());
        _assertTopology(tournament, roots[1], 1, 3, block.number);
        _assertClock(tournament, roots[1], false, MAX_ALLOWANCE, 0);
        _assertClock(tournament, roots[2], true, MAX_ALLOWANCE, START_BLOCK);
        _assertCounters(tournament, 4, 2, 0, 1, 0);

        Match.Id memory secondMatch = Match.Id(roots[2], roots[3]);
        _winSecondAtDeadline(
            tournament,
            secondMatch,
            SmallTwoLevelClaims.childTreeVariant(claim, CONTESTED_SEGMENT, 3)
        );
        assertFalse(tournament.getMatch(secondMatch.hashFromId()).exists());
    }

    function _resolveSecondChildWave(
        InspectableTournament tournament,
        uint8 claim,
        Tree.Node[4] storage roots
    ) private {
        Match.Id memory survivorMatch = Match.Id(roots[1], roots[3]);
        _winSecondAtDeadline(
            tournament,
            survivorMatch,
            SmallTwoLevelClaims.childTreeVariant(claim, CONTESTED_SEGMENT, 3)
        );
        assertFalse(tournament.getMatch(survivorMatch.hashFromId()).exists());
    }

    function _winSecondAtDeadline(
        InspectableTournament tournament,
        Match.Id memory matchId,
        SmallFullTree.Data memory winner
    ) private {
        Time.Instant current = Time.Instant.wrap(uint64(block.number));
        (Clock.State memory clockOne,) =
            tournament.getCommitment(matchId.commitmentOne);
        (Clock.State memory clockTwo,) =
            tournament.getCommitment(matchId.commitmentTwo);
        assertTrue(clockOne.remainingAt(current).isZero());
        assertTrue(clockOne.overdueByAt(current).isZero());
        assertFalse(clockTwo.isRunning());
        assertEq(
            Time.Duration.unwrap(clockTwo.remainingAt(current)), MAX_ALLOWANCE
        );

        assertTrue(tournament.canWinMatchByTimeout(matchId));
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = winner.children(height, 0);
        tournament.winMatchByTimeout(matchId, left, right);
    }

    function _propagateChild(InspectableTournament tournament, uint8 claim)
        private
    {
        SmallFullTree.Data memory winner = SmallTwoLevelClaims.rootTree(claim);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        parent.winInnerTournament(tournament, left, right);
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private returns (Tree.Node root) {
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = tree.children(height, 0);
        uint256 bond = tournament.bondValue();
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
        return tree.root();
    }

    function _assertTopology(
        InspectableTournament tournament,
        Tree.Node expectedDangling,
        uint256 expectedMatches,
        uint256 expectedPopulation,
        uint256 expectedLastDeleted
    ) private view {
        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            tournament.observedTopology();
        _assertNodeEq(dangling, expectedDangling);
        assertEq(matches, expectedMatches);
        assertEq(2 * matches + (dangling.isZero() ? 0 : 1), expectedPopulation);
        assertEq(Time.Instant.unwrap(lastDeleted), expectedLastDeleted);
    }

    function _assertCounters(
        InspectableTournament tournament,
        uint256 joined,
        uint256 created,
        uint256 advanced,
        uint256 deleted,
        uint256 children
    ) private view {
        assertEq(tournament.getCommitmentJoinedCount(), joined);
        assertEq(tournament.getMatchCreatedCount(), created);
        assertEq(tournament.getMatchAdvancedCount(), advanced);
        assertEq(tournament.getMatchDeletedCount(), deleted);
        assertEq(tournament.getNewInnerTournamentCount(), children);
    }

    function _assertClock(
        InspectableTournament tournament,
        Tree.Node root,
        bool expectedRunning,
        uint64 expectedAllowance,
        uint256 expectedStart
    ) private view {
        (Clock.State memory clock,) = tournament.getCommitment(root);
        assertEq(clock.isRunning(), expectedRunning);
        assertEq(Time.Duration.unwrap(clock.allowance), expectedAllowance);
        assertEq(Time.Instant.unwrap(clock.startInstant), expectedStart);
    }

    function _assertSealedMatch(Match.Id memory matchId) private view {
        Match.State memory state = parent.getMatch(matchId.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
    }

    function _assertOrigin(
        InspectableTournament tournament,
        Match.Id memory expected
    ) private view {
        Match.Id memory origin = parent.observedOriginatingMatch(tournament);
        _assertNodeEq(origin.commitmentOne, expected.commitmentOne);
        _assertNodeEq(origin.commitmentTwo, expected.commitmentTwo);
    }

    function _assertClearedOrigin(InspectableTournament tournament)
        private
        view
    {
        Match.Id memory origin = parent.observedOriginatingMatch(tournament);
        assertTrue(origin.commitmentOne.isZero());
        assertTrue(origin.commitmentTwo.isZero());
    }

    function _tournamentDeadline(InspectableTournament tournament)
        private
        view
        returns (uint256)
    {
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        return uint256(Time.Instant.unwrap(args.startInstant))
            + Time.Duration.unwrap(args.allowance);
    }

    function _claimer(uint8 index) private pure returns (address) {
        if (index == 0) return CLAIMER_ONE;
        if (index == 1) return CLAIMER_TWO;
        if (index == 2) return CLAIMER_THREE;
        if (index == 3) return CLAIMER_FOUR;
        revert();
    }

    function _assertNodeEq(Tree.Node actual, Tree.Node expected) private pure {
        assertEq(Tree.Node.unwrap(actual), Tree.Node.unwrap(expected));
    }
}
