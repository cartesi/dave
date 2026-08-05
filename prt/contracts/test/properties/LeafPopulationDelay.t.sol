// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {
    SmallSingleLevelTournamentFactory
} from "../fixtures/SmallSingleLevelTournament.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;
using TournamentInspector for InspectableTournament;

/// @dev Production-path lower-bound traces for sequential leaf-level clock
/// windows. These schedules characterize reachable delay; they do not prove
/// that either schedule is globally optimal against every arrival strategy.
contract LeafPopulationDelayTest is Test {
    using Clock for Clock.State;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Duration;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    uint64 internal constant HEIGHT = 3;
    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant MAX_FUZZ_ALLOWANCE = 1_000_000;

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    address internal constant CLAIMER_THREE = address(0xca11);

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));

    struct Fixture {
        InspectableTournament tournament;
        SmallFullTree.Data one;
        SmallFullTree.Data two;
        SmallFullTree.Data three;
        Match.Id firstMatch;
        bool hasThird;
    }

    function setUp() public {
        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);
        vm.deal(CLAIMER_ONE, 100 ether);
        vm.deal(CLAIMER_TWO, 100 ether);
        vm.deal(CLAIMER_THREE, 100 ether);
    }

    function testZeroResponseBudgetLeavesOneBlockOfSurvivorTime() public {
        _runSchedules(11, 0);
    }

    function testPositiveResponseBudgetAddsOnlyItsDiscount() public {
        _runSchedules(11, 4);
    }

    function testFuzzSequentialLeafClockWindows(
        uint64 rawAllowance,
        uint64 rawResponseBudget
    ) public {
        uint64 allowance = uint64(
            bound(uint256(rawAllowance), 2, MAX_FUZZ_ALLOWANCE)
        );
        uint64 responseBudget =
            uint64(bound(uint256(rawResponseBudget), 0, allowance - 1));

        _runSchedules(allowance, responseBudget);
    }

    function _runSchedules(uint64 allowance, uint64 responseBudget) private {
        assertGe(allowance, 2);
        assertLt(responseBudget, allowance);

        SmallSingleLevelTournamentFactory factory = new SmallSingleLevelTournamentFactory(
            Time.Duration.wrap(responseBudget), Time.Duration.wrap(allowance)
        );
        Fixture memory pair = _newFixture(factory, false, allowance);
        Fixture memory list = _newFixture(factory, true, allowance);

        uint64 firstResponse = START_BLOCK + allowance - 1;
        vm.roll(firstResponse);
        uint64 survivorBalance = _survivorBalance(allowance, responseBudget);
        _advanceFirstMatch(pair, allowance, survivorBalance, firstResponse);
        _advanceFirstMatch(list, allowance, survivorBalance, firstResponse);

        uint64 firstDeletion = START_BLOCK + 2 * allowance - 1;
        vm.roll(firstDeletion - 1);
        _assertTimeoutUnavailable(
            pair.tournament,
            pair.firstMatch,
            pair.two.root(),
            allowance,
            firstResponse,
            firstDeletion - 1
        );
        _assertTimeoutUnavailable(
            list.tournament,
            list.firstMatch,
            list.two.root(),
            allowance,
            firstResponse,
            firstDeletion - 1
        );

        vm.roll(firstDeletion);
        _resolvePair(
            pair, allowance, survivorBalance, firstResponse, firstDeletion
        );
        Match.Id memory repaired = _resolveIntoWaitingClaim(
            list, allowance, survivorBalance, firstResponse, firstDeletion
        );

        uint64 finalDeletion = START_BLOCK + 3 * allowance - 1;
        vm.roll(finalDeletion - 1);
        _assertTimeoutUnavailable(
            list.tournament,
            repaired,
            list.three.root(),
            allowance,
            firstDeletion,
            finalDeletion - 1
        );

        vm.roll(finalDeletion);
        _resolveRepairedMatch(
            list,
            repaired,
            allowance,
            survivorBalance,
            firstResponse,
            firstDeletion,
            finalDeletion
        );

        // Each schedule has one response. Its discount is the only extra term
        // in the independent potential identity.
        assertEq(
            uint256(firstDeletion - START_BLOCK) + survivorBalance,
            2 * uint256(allowance) + responseBudget
        );
        assertEq(
            uint256(finalDeletion - START_BLOCK) + survivorBalance,
            3 * uint256(allowance) + responseBudget
        );
    }

    function _newFixture(
        SmallSingleLevelTournamentFactory factory,
        bool withThird,
        uint64 allowance
    ) private returns (Fixture memory fixture) {
        fixture.tournament = InspectableTournament(
            address(
                factory.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        fixture.one = SmallFullTree.build(bytes32(uint256(1)), HEIGHT);
        fixture.two = SmallFullTree.build(bytes32(uint256(2)), HEIGHT);
        fixture.three = SmallFullTree.build(bytes32(uint256(3)), HEIGHT);
        fixture.hasThird = withThird;

        _join(fixture.tournament, fixture.one, CLAIMER_ONE);
        _join(fixture.tournament, fixture.two, CLAIMER_TWO);
        fixture.firstMatch = Match.Id(fixture.one.root(), fixture.two.root());
        assertTrue(
            fixture.tournament.getMatch(fixture.firstMatch.hashFromId())
                .exists()
        );
        if (withThird) {
            // The odd claim joins in the same block, after the pair is live.
            _join(fixture.tournament, fixture.three, CLAIMER_THREE);
        }

        _assertInitialPopulation(fixture, allowance);
    }

    function _assertInitialPopulation(Fixture memory fixture, uint64 allowance)
        private
        view
    {
        Tree.Node expectedDangling =
            fixture.hasThird ? fixture.three.root() : Tree.ZERO_NODE;
        _assertTopology(
            fixture.tournament, expectedDangling, 1, fixture.hasThird ? 3 : 2, 0
        );
        _assertClock(
            fixture.tournament, fixture.one.root(), true, allowance, START_BLOCK
        );
        _assertClock(
            fixture.tournament, fixture.two.root(), false, allowance, 0
        );
        if (fixture.hasThird) {
            _assertClock(
                fixture.tournament, fixture.three.root(), false, allowance, 0
            );
        }

        Match.State memory state =
            fixture.tournament.getMatch(fixture.firstMatch.hashFromId());
        assertTrue(state.exists());
        assertEq(state.currentHeight, HEIGHT);
        assertTrue(state.otherParent.eq(fixture.one.root()));
        (Tree.Node twoLeft, Tree.Node twoRight) =
            fixture.two.children(HEIGHT, 0);
        assertTrue(state.leftNode.eq(twoLeft));
        assertTrue(state.rightNode.eq(twoRight));

        _assertCounters(fixture.tournament, fixture.hasThird ? 3 : 2, 1, 0, 0);
        assertFalse(fixture.tournament.isClosed());
        assertFalse(fixture.tournament.isFinished());
    }

    function _advanceFirstMatch(
        Fixture memory fixture,
        uint64 allowance,
        uint64 survivorBalance,
        uint64 responseInstant
    ) private {
        (Tree.Node left, Tree.Node right) = fixture.one.children(HEIGHT, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) =
            fixture.one.children(HEIGHT - 1, 0);
        fixture.tournament
            .advanceMatch(fixture.firstMatch, left, right, nextLeft, nextRight);

        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        _assertClock(
            fixture.tournament,
            fixture.two.root(),
            true,
            allowance,
            responseInstant
        );
        if (fixture.hasThird) {
            _assertClock(
                fixture.tournament, fixture.three.root(), false, allowance, 0
            );
        }

        Match.State memory state =
            fixture.tournament.getMatch(fixture.firstMatch.hashFromId());
        assertTrue(state.exists());
        assertEq(state.currentHeight, HEIGHT - 1);
        assertEq(state.runningLeafPosition, 0);
        (Tree.Node twoLeft,) = fixture.two.children(HEIGHT, 0);
        assertTrue(state.otherParent.eq(twoLeft));
        assertTrue(state.leftNode.eq(nextLeft));
        assertTrue(state.rightNode.eq(nextRight));

        Tree.Node expectedDangling =
            fixture.hasThird ? fixture.three.root() : Tree.ZERO_NODE;
        _assertTopology(
            fixture.tournament, expectedDangling, 1, fixture.hasThird ? 3 : 2, 0
        );
        _assertCounters(fixture.tournament, fixture.hasThird ? 3 : 2, 1, 1, 0);
    }

    function _resolvePair(
        Fixture memory fixture,
        uint64 allowance,
        uint64 survivorBalance,
        uint64 responseInstant,
        uint64 deletionInstant
    ) private {
        _assertFirstTimeoutReady(
            fixture,
            allowance,
            survivorBalance,
            responseInstant,
            deletionInstant
        );
        (Tree.Node left, Tree.Node right) = fixture.one.children(HEIGHT, 0);
        fixture.tournament.winMatchByTimeout(fixture.firstMatch, left, right);

        assertFalse(
            fixture.tournament.getMatch(fixture.firstMatch.hashFromId())
                .exists()
        );
        _assertTopology(
            fixture.tournament, fixture.one.root(), 0, 1, deletionInstant
        );
        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        _assertClock(
            fixture.tournament,
            fixture.two.root(),
            true,
            allowance,
            responseInstant
        );
        _assertCounters(fixture.tournament, 2, 1, 1, 1);
        assertEq(
            fixture.tournament.observedClaimer(fixture.one.root()), CLAIMER_ONE
        );
        assertEq(
            fixture.tournament.observedClaimer(fixture.two.root()), address(0)
        );
        _assertWinner(
            fixture.tournament, fixture.one, survivorBalance, deletionInstant
        );
    }

    function _resolveIntoWaitingClaim(
        Fixture memory fixture,
        uint64 allowance,
        uint64 survivorBalance,
        uint64 responseInstant,
        uint64 deletionInstant
    ) private returns (Match.Id memory repaired) {
        _assertFirstTimeoutReady(
            fixture,
            allowance,
            survivorBalance,
            responseInstant,
            deletionInstant
        );
        (Tree.Node left, Tree.Node right) = fixture.one.children(HEIGHT, 0);
        fixture.tournament.winMatchByTimeout(fixture.firstMatch, left, right);

        assertFalse(
            fixture.tournament.getMatch(fixture.firstMatch.hashFromId())
                .exists()
        );
        repaired = Match.Id(fixture.three.root(), fixture.one.root());
        Match.State memory state =
            fixture.tournament.getMatch(repaired.hashFromId());
        assertTrue(state.exists());
        assertEq(state.currentHeight, HEIGHT);
        assertTrue(state.otherParent.eq(fixture.three.root()));
        assertTrue(state.leftNode.eq(left));
        assertTrue(state.rightNode.eq(right));

        _assertTopology(
            fixture.tournament, Tree.ZERO_NODE, 1, 2, deletionInstant
        );
        _assertClock(
            fixture.tournament,
            fixture.three.root(),
            true,
            allowance,
            deletionInstant
        );
        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        _assertClock(
            fixture.tournament,
            fixture.two.root(),
            true,
            allowance,
            responseInstant
        );
        _assertCounters(fixture.tournament, 3, 2, 1, 1);
        assertEq(
            fixture.tournament.observedClaimer(fixture.one.root()), CLAIMER_ONE
        );
        assertEq(
            fixture.tournament.observedClaimer(fixture.two.root()), address(0)
        );
        assertEq(
            fixture.tournament.observedClaimer(fixture.three.root()),
            CLAIMER_THREE
        );

        // Closing forbids new joins, but the remaining match must still be
        // resolvable or the global deadline would strand live population.
        assertTrue(fixture.tournament.isClosed());
        assertFalse(fixture.tournament.isFinished());
    }

    function _assertFirstTimeoutReady(
        Fixture memory fixture,
        uint64 allowance,
        uint64 survivorBalance,
        uint64 responseInstant,
        uint64 current
    ) private view {
        assertEq(vm.getBlockNumber(), current);
        assertTrue(fixture.tournament.isClosed());
        assertFalse(fixture.tournament.isFinished());
        assertTrue(fixture.tournament.canWinMatchByTimeout(fixture.firstMatch));

        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        _assertClock(
            fixture.tournament,
            fixture.two.root(),
            true,
            allowance,
            responseInstant
        );
        (Clock.State memory expired,) =
            fixture.tournament.getCommitment(fixture.two.root());
        Time.Instant instant = Time.Instant.wrap(current);
        assertTrue(expired.remainingAt(instant).isZero());
        assertTrue(expired.overdueByAt(instant).isZero());
    }

    function _assertTimeoutUnavailable(
        InspectableTournament tournament,
        Match.Id memory matchId,
        Tree.Node runningRoot,
        uint64 allowance,
        uint64 startInstant,
        uint64 current
    ) private view {
        assertEq(vm.getBlockNumber(), current);
        assertEq(current, startInstant + allowance - 1);
        assertTrue(tournament.isClosed());
        assertFalse(tournament.isFinished());
        assertFalse(tournament.canWinMatchByTimeout(matchId));

        (Clock.State memory running,) = tournament.getCommitment(runningRoot);
        Time.Instant instant = Time.Instant.wrap(current);
        assertTrue(running.isRunning());
        assertEq(Time.Duration.unwrap(running.remainingAt(instant)), 1);
        assertTrue(running.overdueByAt(instant).isZero());
    }

    function _resolveRepairedMatch(
        Fixture memory fixture,
        Match.Id memory repaired,
        uint64 allowance,
        uint64 survivorBalance,
        uint64 firstResponse,
        uint64 firstDeletion,
        uint64 finalDeletion
    ) private {
        assertEq(vm.getBlockNumber(), finalDeletion);
        assertTrue(fixture.tournament.isClosed());
        assertFalse(fixture.tournament.isFinished());
        assertTrue(fixture.tournament.canWinMatchByTimeout(repaired));

        _assertClock(
            fixture.tournament,
            fixture.three.root(),
            true,
            allowance,
            firstDeletion
        );
        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        (Clock.State memory expired,) =
            fixture.tournament.getCommitment(fixture.three.root());
        Time.Instant instant = Time.Instant.wrap(finalDeletion);
        assertTrue(expired.remainingAt(instant).isZero());
        assertTrue(expired.overdueByAt(instant).isZero());

        (Tree.Node left, Tree.Node right) = fixture.one.children(HEIGHT, 0);
        fixture.tournament.winMatchByTimeout(repaired, left, right);

        assertFalse(fixture.tournament.getMatch(repaired.hashFromId()).exists());
        _assertTopology(
            fixture.tournament, fixture.one.root(), 0, 1, finalDeletion
        );
        _assertClock(
            fixture.tournament, fixture.one.root(), false, survivorBalance, 0
        );
        _assertClock(
            fixture.tournament,
            fixture.two.root(),
            true,
            allowance,
            firstResponse
        );
        _assertClock(
            fixture.tournament,
            fixture.three.root(),
            true,
            allowance,
            firstDeletion
        );
        _assertCounters(fixture.tournament, 3, 2, 1, 2);
        assertEq(
            fixture.tournament.observedClaimer(fixture.one.root()), CLAIMER_ONE
        );
        assertEq(
            fixture.tournament.observedClaimer(fixture.two.root()), address(0)
        );
        assertEq(
            fixture.tournament.observedClaimer(fixture.three.root()), address(0)
        );
        _assertWinner(
            fixture.tournament, fixture.one, survivorBalance, finalDeletion
        );
    }

    function _assertWinner(
        InspectableTournament tournament,
        SmallFullTree.Data memory expected,
        uint64 expectedBalance,
        uint64 expectedFinishedAt
    ) private view {
        assertTrue(tournament.isClosed());
        assertTrue(tournament.isFinished());
        (bool timeKnown, Time.Instant finishedAt) = tournament.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), expectedFinishedAt);

        (bool finished, Tree.Node winner, Machine.Hash finalState) =
            tournament.arbitrationResult();
        assertTrue(finished);
        assertTrue(winner.eq(expected.root()));
        assertTrue(finalState.eq(expected.finalState()));
        (Clock.State memory winnerClock,) =
            tournament.getCommitment(expected.root());
        assertFalse(winnerClock.isRunning());
        assertEq(Time.Duration.unwrap(winnerClock.allowance), expectedBalance);
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private {
        (Tree.Node left, Tree.Node right) = tree.children(HEIGHT, 0);
        uint256 bond = tournament.bondValue();
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
    }

    function _assertTopology(
        InspectableTournament tournament,
        Tree.Node expectedDangling,
        uint256 expectedMatches,
        uint256 expectedPopulation,
        uint64 expectedLastDeleted
    ) private view {
        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            tournament.observedTopology();
        assertTrue(dangling.eq(expectedDangling));
        assertEq(matches, expectedMatches);
        assertEq(2 * matches + (dangling.isZero() ? 0 : 1), expectedPopulation);
        assertEq(Time.Instant.unwrap(lastDeleted), expectedLastDeleted);
    }

    function _assertCounters(
        InspectableTournament tournament,
        uint256 joined,
        uint256 created,
        uint256 advanced,
        uint256 deleted
    ) private view {
        assertEq(tournament.getCommitmentJoinedCount(), joined);
        assertEq(tournament.getMatchCreatedCount(), created);
        assertEq(tournament.getMatchAdvancedCount(), advanced);
        assertEq(tournament.getMatchDeletedCount(), deleted);
        assertEq(tournament.getNewInnerTournamentCount(), 0);
    }

    function _assertClock(
        InspectableTournament tournament,
        Tree.Node root,
        bool expectedRunning,
        uint64 expectedAllowance,
        uint64 expectedStart
    ) private view {
        (Clock.State memory clock,) = tournament.getCommitment(root);
        assertTrue(clock.isInitialized());
        assertEq(clock.isRunning(), expectedRunning);
        assertEq(Time.Duration.unwrap(clock.allowance), expectedAllowance);
        assertEq(Time.Instant.unwrap(clock.startInstant), expectedStart);
    }

    function _survivorBalance(uint64 allowance, uint64 responseBudget)
        private
        pure
        returns (uint64)
    {
        assert(responseBudget < allowance);
        return responseBudget + 1;
    }
}
