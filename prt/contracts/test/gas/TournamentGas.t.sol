// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Gas} from "src/tournament/libs/Gas.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {
    ConfigurableCommitmentFixture
} from "../fixtures/ConfigurableCommitmentFixture.sol";

library GasTestGeometry {
    uint64 internal constant LEVELS = 2;
    uint64 internal constant ROOT_LOG2_STEP = 37;
    uint64 internal constant ROOT_HEIGHT = 55;
    uint64 internal constant LEAF_LOG2_STEP = 0;
    uint64 internal constant LEAF_HEIGHT = 37;
    uint64 internal constant MATCH_EFFORT = 300;
    uint64 internal constant MAX_ALLOWANCE = 1_000_000;
}

contract GasParametersProvider is ITournamentParametersProvider {
    function tournamentParameters(uint64 level)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        require(level < GasTestGeometry.LEVELS);
        return TournamentParameters({
            levels: GasTestGeometry.LEVELS,
            log2step: level == 0
                ? GasTestGeometry.ROOT_LOG2_STEP
                : GasTestGeometry.LEAF_LOG2_STEP,
            height: level == 0
                ? GasTestGeometry.ROOT_HEIGHT
                : GasTestGeometry.LEAF_HEIGHT,
            matchEffort: Time.Duration.wrap(GasTestGeometry.MATCH_EFFORT),
            maxAllowance: Time.Duration.wrap(GasTestGeometry.MAX_ALLOWANCE)
        });
    }
}

contract GasStateTransition is IStateTransition {
    function transitionState(
        bytes32 machineState,
        uint256,
        bytes calldata,
        IDataProvider
    ) external pure override returns (bytes32) {
        return machineState;
    }
}

abstract contract TournamentGasTest is Test, ConfigurableCommitmentFixture {
    using Tree for Tree.Node;

    enum ShortSide {
        ONE,
        TWO
    }

    struct Measurement {
        uint256 allocationUnits;
        uint256 completeCallGas;
    }

    uint64 internal constant ROOT_HEIGHT = GasTestGeometry.ROOT_HEIGHT;
    uint64 internal constant LEAF_HEIGHT = GasTestGeometry.LEAF_HEIGHT;
    uint64 internal constant MATCH_EFFORT = GasTestGeometry.MATCH_EFFORT;
    uint64 internal constant MAX_ALLOWANCE = GasTestGeometry.MAX_ALLOWANCE;
    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant CLOCK_CHARGE = 100;
    uint64 internal constant TIMEOUT_OVERDUE = 1;

    Machine.Hash internal constant STATE_A =
        Machine.Hash.wrap(bytes32(uint256(0xa)));
    Machine.Hash internal constant STATE_B =
        Machine.Hash.wrap(bytes32(uint256(0xb)));
    Machine.Hash internal constant STATE_C =
        Machine.Hash.wrap(bytes32(uint256(0xc)));

    address internal constant CLAIMER_A = address(0xa11ce);
    address internal constant CLAIMER_B = address(0xb0b);
    address internal constant CLAIMER_C = address(0xca11);

    MultiLevelTournamentFactory internal immutable FACTORY;

    ITournament internal tournament;
    ITournament internal childTournament;
    Match.Id internal matchId;
    uint256 internal fundedBalance;
    uint256 internal childFundedBalance;
    uint256 internal resolutionBlock;
    uint256 internal childEliminationBlock;
    uint256 internal expectedParentWinnerAllowance;

    constructor() {
        FACTORY = new MultiLevelTournamentFactory(
            new Tournament(),
            new GasParametersProvider(),
            new GasStateTransition()
        );
    }

    receive() external payable {}

    function _initializeFixture() internal {
        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);
        initializeCommitmentFixture(ROOT_HEIGHT, STATE_A, STATE_B, STATE_C);
    }

    function _rootMatchFixture(CommitmentShape opponent) internal {
        tournament = FACTORY.instantiate(STATE_A, IDataProvider(address(0)));
        Tree.Node one = _join(tournament, CommitmentShape.SAME, CLAIMER_A);
        Tree.Node two = _join(tournament, opponent, CLAIMER_B);
        matchId = Match.Id(one, two);
        fundedBalance = 2 * tournament.bondValue();
    }

    function _leafMatchFixture(CommitmentShape opponent) internal {
        tournament = FACTORY.instantiateInner(
            STATE_A,
            sameNode(ROOT_HEIGHT),
            STATE_A,
            rightmostNode(ROOT_HEIGHT),
            STATE_B,
            Time.Duration.wrap(MAX_ALLOWANCE),
            0,
            1,
            IDataProvider(address(0))
        );
        Tree.Node one = _join(tournament, CommitmentShape.SAME, CLAIMER_A);
        Tree.Node two = _join(tournament, opponent, CLAIMER_B);
        matchId = Match.Id(one, two);
        fundedBalance = 2 * tournament.bondValue();
    }

    function _join(ITournament target, CommitmentShape shape, address claimer)
        internal
        returns (Tree.Node root)
    {
        (,,, uint64 height) = target.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = children(shape, height);
        Machine.Hash committedFinalState = finalState(shape, height);
        bytes32[] memory proof = finalProof(shape, height);
        uint256 bond = target.bondValue();

        vm.deal(claimer, bond);
        vm.prank(claimer);
        target.joinTournament{value: bond}(
            committedFinalState, proof, left, right
        );
        root = node(shape, height);
    }

    function _addDangling(CommitmentShape shape, address claimer)
        internal
        returns (Tree.Node root)
    {
        root = _join(tournament, shape, claimer);
        fundedBalance += tournament.bondValue();
    }

    function _advance(
        ITournament target,
        Match.Id memory id,
        CommitmentShape responder,
        uint64 currentHeight
    ) internal {
        (Tree.Node left, Tree.Node right) = children(responder, currentHeight);
        (Tree.Node newLeft, Tree.Node newRight) =
            children(responder, currentHeight - 1);
        target.advanceMatch(id, left, right, newLeft, newRight);
    }

    function _advanceToSealable(uint64 height, CommitmentShape opponent)
        internal
    {
        CommitmentShape responder =
            _advanceFromToSealable(height, CommitmentShape.SAME, opponent);
        assertEq(uint256(responder), uint256(CommitmentShape.SAME));
    }

    function _advanceFromToSealable(
        uint64 current,
        CommitmentShape responder,
        CommitmentShape opponent
    ) internal returns (CommitmentShape) {
        for (; current > 1; --current) {
            _advance(tournament, matchId, responder, current);
            responder = responder == CommitmentShape.SAME
                ? opponent
                : CommitmentShape.SAME;
        }
        return responder;
    }

    function _sealCall(bool leaf) internal view returns (bytes memory) {
        uint64 height = leaf ? LEAF_HEIGHT : ROOT_HEIGHT;
        (Tree.Node left, Tree.Node right) = children(CommitmentShape.SAME, 1);
        bytes32[] memory agreeProof = finalProof(CommitmentShape.SAME, height);

        if (leaf) {
            return abi.encodeCall(
                ITournament.sealLeafMatch,
                (matchId, left, right, STATE_A, agreeProof)
            );
        }
        return abi.encodeCall(
            ITournament.sealInnerMatchAndCreateInnerTournament,
            (matchId, left, right, STATE_A, agreeProof)
        );
    }

    function _callInSetup(bytes memory callData) internal {
        (bool success, bytes memory ret) = address(tournament).call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _sealInnerAndCaptureChild() internal returns (ITournament child) {
        vm.recordLogs();
        _callInSetup(_sealCall(false));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 childEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(tournament)
                    || entry.topics[0]
                        != ITournament.NewInnerTournament.selector
            ) {
                continue;
            }

            ++childEvents;
            child = ITournament(address(uint160(uint256(entry.topics[2]))));
        }
        assertEq(childEvents, 1);
        assertNotEq(address(child), address(0));
    }

    function _initializeSingleClaimInnerWinnerFixture(
        CommitmentShape childWinner,
        CommitmentShape parentWinner,
        bool addDangling
    ) internal {
        _initializeSealedInnerParent(addDangling);

        Tree.Node childWinnerRoot = _join(
            childTournament,
            childWinner,
            childWinner == CommitmentShape.SAME ? CLAIMER_A : CLAIMER_B
        );
        childFundedBalance = address(childTournament).balance;

        (Clock.State memory childClock,) =
            childTournament.getCommitment(childWinnerRoot);
        assertFalse(Clock.isRunning(childClock));
        assertEq(Time.Duration.unwrap(childClock.allowance), MAX_ALLOWANCE);

        ITournament.TournamentArguments memory childArgs =
            childTournament.tournamentArguments();
        uint256 childFinished = uint256(
            Time.Instant.unwrap(childArgs.startInstant)
        ) + Time.Duration.unwrap(childArgs.allowance);
        childEliminationBlock = childFinished + MAX_ALLOWANCE;
        resolutionBlock = childFinished + TIMEOUT_OVERDUE;
        expectedParentWinnerAllowance = MAX_ALLOWANCE - TIMEOUT_OVERDUE;
        vm.roll(resolutionBlock);
        _assertChildWinnerReady(childWinnerRoot, parentWinner);
    }

    function _initializeResolvedInnerWinnerFixture(
        CommitmentShape childWinner,
        CommitmentShape parentWinner,
        bool addDangling
    ) internal {
        _initializeSealedInnerParent(addDangling);

        CommitmentShape childLoser = childWinner == CommitmentShape.SAME
            ? CommitmentShape.RIGHTMOST_DIFFERENT
            : CommitmentShape.SAME;
        Tree.Node childLoserRoot = _join(childTournament, childLoser, CLAIMER_A);
        Tree.Node childWinnerRoot =
            _join(childTournament, childWinner, CLAIMER_B);
        Match.Id memory childMatchId = Match.Id(childLoserRoot, childWinnerRoot);
        childFundedBalance = address(childTournament).balance;

        (Clock.State memory loserClock,) =
            childTournament.getCommitment(childLoserRoot);
        assertTrue(Clock.isRunning(loserClock));
        uint256 childMatchResolution = uint256(
            Time.Instant.unwrap(loserClock.startInstant)
        ) + Time.Duration.unwrap(loserClock.allowance) + TIMEOUT_OVERDUE;
        vm.roll(childMatchResolution);
        (Tree.Node left, Tree.Node right) = children(childWinner, LEAF_HEIGHT);
        childTournament.winMatchByTimeout(childMatchId, left, right);

        assertFalse(
            Match.exists(
                childTournament.getMatch(Match.hashFromId(childMatchId))
            )
        );
        (Clock.State memory storedWinnerClock,) =
            childTournament.getCommitment(childWinnerRoot);
        assertFalse(Clock.isRunning(storedWinnerClock));
        assertEq(
            Time.Duration.unwrap(storedWinnerClock.allowance),
            MAX_ALLOWANCE - TIMEOUT_OVERDUE
        );

        (bool finished, Time.Instant childFinished) =
            childTournament.timeFinished();
        assertTrue(finished);
        assertEq(Time.Instant.unwrap(childFinished), childMatchResolution);
        childEliminationBlock = uint256(Time.Instant.unwrap(childFinished))
            + Time.Duration.unwrap(storedWinnerClock.allowance);
        resolutionBlock = childEliminationBlock - TIMEOUT_OVERDUE;
        expectedParentWinnerAllowance = TIMEOUT_OVERDUE;
        vm.roll(resolutionBlock);
        _assertChildWinnerReady(childWinnerRoot, parentWinner);
    }

    function _assertChildWinnerReady(
        Tree.Node childWinnerRoot,
        CommitmentShape parentWinner
    ) private view {
        assertTrue(childTournament.isFinished());
        assertFalse(childTournament.canBeEliminated());
        (
            bool finished,
            Tree.Node contestedCommitment,
            Tree.Node actualChildWinner,
            Clock.State memory returnedClock
        ) = childTournament.innerTournamentWinner();
        assertTrue(finished);
        assertTrue(actualChildWinner.eq(childWinnerRoot));
        assertTrue(contestedCommitment.eq(node(parentWinner, ROOT_HEIGHT)));
        assertFalse(Clock.isRunning(returnedClock));
        assertEq(
            Time.Duration.unwrap(returnedClock.allowance),
            expectedParentWinnerAllowance
        );
    }

    function _initializeSealedInnerParent(bool addDangling) private {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.SECOND_DIFFERENT);
        if (addDangling) {
            _addDangling(CommitmentShape.FIRST_DIFFERENT, CLAIMER_C);
        }
        _advanceToSealable(ROOT_HEIGHT, CommitmentShape.SECOND_DIFFERENT);
        childTournament = _sealInnerAndCaptureChild();

        Match.State memory parentMatch =
            tournament.getMatch(Match.hashFromId(matchId));
        assertTrue(Match.isSealed(parentMatch));
        assertEq(parentMatch.runningLeafPosition, 1);
        assertEq(tournament.getNewInnerTournamentCount(), 1);
    }

    function _initializeNoWinnerInnerEliminationFixture() internal {
        _initializeSealedInnerParent(false);
        childFundedBalance = 0;
        ITournament.TournamentArguments memory childArgs =
            childTournament.tournamentArguments();
        resolutionBlock = uint256(Time.Instant.unwrap(childArgs.startInstant))
            + Time.Duration.unwrap(childArgs.allowance);
        childEliminationBlock = resolutionBlock;
        vm.roll(resolutionBlock);

        assertTrue(childTournament.isFinished());
        assertTrue(childTournament.canBeEliminated());
    }

    function _initializeSealedLeafTimeoutFixture(
        ShortSide shortSide,
        bool addDangling
    ) internal {
        _initializeFixture();
        _leafMatchFixture(CommitmentShape.SECOND_DIFFERENT);
        if (addDangling) {
            _addDangling(CommitmentShape.FIRST_DIFFERENT, CLAIMER_C);
        }

        uint64 current = LEAF_HEIGHT;
        CommitmentShape responder = CommitmentShape.SAME;
        if (shortSide == ShortSide.ONE) {
            vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + CLOCK_CHARGE);
            _advance(tournament, matchId, responder, current);
            --current;
            responder = CommitmentShape.SECOND_DIFFERENT;
        } else {
            assertEq(uint256(shortSide), uint256(ShortSide.TWO));
            _advance(tournament, matchId, responder, current);
            --current;
            responder = CommitmentShape.SECOND_DIFFERENT;
            vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + CLOCK_CHARGE);
            _advance(tournament, matchId, responder, current);
            --current;
            responder = CommitmentShape.SAME;
        }

        responder = _advanceFromToSealable(
            current, responder, CommitmentShape.SECOND_DIFFERENT
        );
        assertEq(uint256(responder), uint256(CommitmentShape.SAME));
        _callInSetup(_sealCall(true));

        Match.State memory state =
            tournament.getMatch(Match.hashFromId(matchId));
        assertTrue(Match.isSealed(state));
        assertEq(state.runningLeafPosition, 1);

        (Clock.State memory clockOne,) =
            tournament.getCommitment(sameNode(LEAF_HEIGHT));
        (Clock.State memory clockTwo,) =
            tournament.getCommitment(secondDifferentNode(LEAF_HEIGHT));
        assertTrue(Clock.isRunning(clockOne));
        assertTrue(Clock.isRunning(clockTwo));
        if (shortSide == ShortSide.ONE) {
            assertEq(
                Time.Duration.unwrap(clockOne.allowance) + CLOCK_CHARGE,
                Time.Duration.unwrap(clockTwo.allowance)
            );
        } else {
            assertEq(
                Time.Duration.unwrap(clockTwo.allowance) + CLOCK_CHARGE,
                Time.Duration.unwrap(clockOne.allowance)
            );
        }
    }

    function _assertNonzeroMatchPosition() internal view {
        Match.State memory state =
            tournament.getMatch(Match.hashFromId(matchId));
        assertGt(state.runningLeafPosition, 0);
    }

    function _deadlinePlus(Tree.Node commitment, uint256 overdue)
        internal
        view
        returns (uint256)
    {
        (Clock.State memory clock,) = tournament.getCommitment(commitment);
        assertTrue(Clock.isRunning(clock));
        return Time.Instant.unwrap(clock.startInstant)
            + Time.Duration.unwrap(clock.allowance) + overdue;
    }

    function _timeoutWinCall(CommitmentShape winner, uint64 height)
        internal
        view
        returns (bytes memory)
    {
        (Tree.Node left, Tree.Node right) = children(winner, height);
        return
            abi.encodeCall(
                ITournament.winMatchByTimeout, (matchId, left, right)
            );
    }

    function _timeoutEliminationCall() internal view returns (bytes memory) {
        return abi.encodeCall(ITournament.eliminateMatchByTimeout, (matchId));
    }

    function _innerWinnerCall(CommitmentShape parentWinner)
        internal
        view
        returns (bytes memory)
    {
        (Tree.Node left, Tree.Node right) = children(parentWinner, ROOT_HEIGHT);
        return abi.encodeCall(
            ITournament.winInnerTournament, (childTournament, left, right)
        );
    }

    function _innerEliminationCall() internal view returns (bytes memory) {
        return
            abi.encodeCall(
                ITournament.eliminateInnerTournament, (childTournament)
            );
    }

    function _activeDoubleEliminationBlock(
        Tree.Node runningCommitment,
        Tree.Node pausedCommitment
    ) internal view returns (uint256) {
        (Clock.State memory runningClock,) = tournament.getCommitment(
            runningCommitment
        );
        (Clock.State memory pausedClock,) =
            tournament.getCommitment(pausedCommitment);
        assertTrue(Clock.isRunning(runningClock));
        assertFalse(Clock.isRunning(pausedClock));

        uint256 boundary = Time.Instant.unwrap(runningClock.startInstant)
            + Time.Duration.unwrap(runningClock.allowance)
            + Time.Duration.unwrap(pausedClock.allowance);
        assertLe(boundary, type(uint64).max);
        Time.Instant boundaryInstant = Time.Instant.wrap(uint64(boundary));
        assertEq(
            Time.Duration
                .unwrap(Clock.overdueByAt(runningClock, boundaryInstant)),
            Time.Duration
                .unwrap(Clock.remainingAt(pausedClock, boundaryInstant))
        );
        return boundary;
    }

    function _leafRaceDoubleEliminationBlock(
        Tree.Node commitmentOne,
        Tree.Node commitmentTwo
    ) internal view returns (uint256) {
        (Clock.State memory clockOne,) = tournament.getCommitment(commitmentOne);
        (Clock.State memory clockTwo,) = tournament.getCommitment(commitmentTwo);
        assertTrue(Clock.isRunning(clockOne));
        assertTrue(Clock.isRunning(clockTwo));
        assertEq(
            Time.Instant.unwrap(clockOne.startInstant),
            Time.Instant.unwrap(clockTwo.startInstant)
        );

        uint256 combinedAllowance = Time.Duration.unwrap(clockOne.allowance)
            + Time.Duration.unwrap(clockTwo.allowance);
        // Both clocks run from one instant. At this ceiling midpoint, one
        // side's live remainder is no greater than the other's overdue time.
        return Time.Instant.unwrap(clockOne.startInstant)
            + (combinedAllowance + 1) / 2;
    }

    function _assertRepairedMatch(
        CommitmentShape dangling,
        CommitmentShape winner,
        uint64 height,
        uint256 expectedWinnerAllowance
    ) internal view {
        Match.Id memory oldId = matchId;
        assertFalse(Match.exists(tournament.getMatch(Match.hashFromId(oldId))));

        Match.Id memory repairedId = Match.Id({
            commitmentOne: node(dangling, height),
            commitmentTwo: node(winner, height)
        });
        assertTrue(
            Match.exists(tournament.getMatch(Match.hashFromId(repairedId)))
        );
        assertEq(tournament.getMatchCreatedCount(), 2);
        assertEq(tournament.getMatchDeletedCount(), 1);

        (Clock.State memory danglingClock,) =
            tournament.getCommitment(node(dangling, height));
        (Clock.State memory winnerClock,) =
            tournament.getCommitment(node(winner, height));
        assertTrue(Clock.isRunning(danglingClock));
        assertFalse(Clock.isRunning(winnerClock));
        assertEq(
            Time.Duration.unwrap(winnerClock.allowance), expectedWinnerAllowance
        );
    }

    function _assertEliminated() internal view {
        Match.Id memory oldId = matchId;
        assertFalse(Match.exists(tournament.getMatch(Match.hashFromId(oldId))));
        assertEq(tournament.getMatchCreatedCount(), 1);
        assertEq(tournament.getMatchDeletedCount(), 1);
        assertTrue(tournament.isFinished());
    }

    function _measureTimeoutWinner(
        string memory label,
        CommitmentShape winner,
        uint64 height,
        uint256 expectedWinnerAllowance
    ) internal returns (Measurement memory result) {
        vm.roll(resolutionBlock);
        result =
            _measure(_timeoutWinCall(winner, height), Gas.WIN_MATCH_BY_TIMEOUT);
        _logMeasurement(label, result);
        _assertReviewedHeadroom(result, Gas.WIN_MATCH_BY_TIMEOUT);

        _assertRepairedMatch(
            CommitmentShape.FIRST_DIFFERENT,
            winner,
            height,
            expectedWinnerAllowance
        );
    }

    function _measureTimeoutElimination(string memory label)
        internal
        returns (Measurement memory result)
    {
        vm.roll(resolutionBlock);
        result =
            _measure(_timeoutEliminationCall(), Gas.ELIMINATE_MATCH_BY_TIMEOUT);
        _logMeasurement(label, result);
        _assertReviewedHeadroom(result, Gas.ELIMINATE_MATCH_BY_TIMEOUT);

        _assertEliminated();
    }

    function _measureInnerWinner(
        string memory label,
        CommitmentShape parentWinner
    ) internal returns (Measurement memory result) {
        vm.roll(resolutionBlock);
        result =
            _measure(_innerWinnerCall(parentWinner), Gas.WIN_INNER_TOURNAMENT);
        _logMeasurement(label, result);
        _assertReviewedHeadroom(result, Gas.WIN_INNER_TOURNAMENT);

        _assertRepairedMatch(
            CommitmentShape.FIRST_DIFFERENT,
            parentWinner,
            ROOT_HEIGHT,
            expectedParentWinnerAllowance
        );
        assertEq(address(childTournament).balance, childFundedBalance);

        (Tree.Node left, Tree.Node right) = children(parentWinner, ROOT_HEIGHT);
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.winInnerTournament(childTournament, left, right);
    }

    function _measureInnerElimination(string memory label)
        internal
        returns (Measurement memory result)
    {
        vm.roll(resolutionBlock);
        result =
            _measure(_innerEliminationCall(), Gas.ELIMINATE_INNER_TOURNAMENT);
        _logMeasurement(label, result);
        _assertReviewedHeadroom(result, Gas.ELIMINATE_INNER_TOURNAMENT);

        _assertEliminated();
        assertTrue(childTournament.canBeEliminated());
        assertEq(address(childTournament).balance, childFundedBalance);
    }

    function _measure(bytes memory callData, uint256 configuredAllocation)
        internal
        returns (Measurement memory result)
    {
        vm.fee(0);
        vm.txGasPrice(1);
        vm.recordLogs();

        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = address(tournament).call(callData);
        result.completeCallGas = gasBefore - gasleft();
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 refundEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(tournament)
                    || entry.topics[0] != ITournament.PartialBondRefund.selector
            ) {
                continue;
            }

            ++refundEvents;
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(this)))));
            assertEq(entry.topics[2], bytes32(uint256(1)));
            (uint256 value, bytes memory callbackRet) =
                abi.decode(entry.data, (uint256, bytes));
            result.allocationUnits = value;
            assertEq(callbackRet, bytes(""));
        }

        assertEq(refundEvents, 1);
        assertGt(result.allocationUnits, Gas.TX);
        assertLt(
            result.allocationUnits, Bond.actionRefundCap(configuredAllocation)
        );
        assertLt(result.allocationUnits, fundedBalance);
    }

    function _logMeasurement(string memory label, Measurement memory result)
        internal
    {
        emit log_named_uint(label, result.allocationUnits);
        uint256 minimumAllocation = _minimumReviewedAllocation(result);
        emit log_named_uint(
            string.concat(label, " reviewed minimum"), minimumAllocation
        );
        emit log_named_uint(
            string.concat(label, " rounded recommendation"),
            _roundUpToThousand(minimumAllocation)
        );
        emit log_named_uint(
            string.concat(label, " complete call"), result.completeCallGas
        );
    }

    function _assertReviewedHeadroom(
        Measurement memory result,
        uint256 allocation
    ) internal pure {
        assertLe(_minimumReviewedAllocation(result), allocation);
    }

    function _assertCalibratedAllocation(
        Measurement memory result,
        uint256 allocation
    ) internal pure {
        assertEq(
            allocation, _roundUpToThousand(_minimumReviewedAllocation(result))
        );
    }

    function _minimumReviewedAllocation(Measurement memory result)
        private
        pure
        returns (uint256)
    {
        uint256 measuredDelta = result.allocationUnits - Gas.TX;
        uint256 proportionalMargin = (measuredDelta + 9) / 10;
        uint256 margin =
            proportionalMargin > 10_000 ? proportionalMargin : 10_000;
        return result.allocationUnits + margin;
    }

    function _roundUpToThousand(uint256 value) private pure returns (uint256) {
        return (value + 999) / 1000 * 1000;
    }
}

contract AdvanceMatchGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.RIGHTMOST_DIFFERENT);
    }

    function testMeasureFirstChargedRightAdvance() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        (Tree.Node left, Tree.Node right) =
            children(CommitmentShape.SAME, ROOT_HEIGHT);
        (Tree.Node newLeft, Tree.Node newRight) =
            children(CommitmentShape.SAME, ROOT_HEIGHT - 1);
        bytes memory callData = abi.encodeCall(
            ITournament.advanceMatch, (matchId, left, right, newLeft, newRight)
        );

        Measurement memory result = _measure(callData, Gas.ADVANCE_MATCH);
        _logMeasurement("advance match", result);
        _assertCalibratedAllocation(result, Gas.ADVANCE_MATCH);

        Match.Id memory id = matchId;
        Match.State memory state = tournament.getMatch(Match.hashFromId(id));
        assertEq(state.currentHeight, ROOT_HEIGHT - 1);
        assertGt(state.runningLeafPosition, 0);
        assertEq(tournament.getMatchAdvancedCount(), 1);
    }
}

contract AdvanceMatchLeftGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.FIRST_DIFFERENT);
    }

    function testMeasureFirstChargedLeftAdvance() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        (Tree.Node left, Tree.Node right) =
            children(CommitmentShape.SAME, ROOT_HEIGHT);
        (Tree.Node newLeft, Tree.Node newRight) =
            children(CommitmentShape.SAME, ROOT_HEIGHT - 1);
        bytes memory callData = abi.encodeCall(
            ITournament.advanceMatch, (matchId, left, right, newLeft, newRight)
        );

        Measurement memory result = _measure(callData, Gas.ADVANCE_MATCH);
        _logMeasurement("advance match left", result);
        _assertReviewedHeadroom(result, Gas.ADVANCE_MATCH);

        Match.State memory state =
            tournament.getMatch(Match.hashFromId(matchId));
        assertEq(state.currentHeight, ROOT_HEIGHT - 1);
        assertEq(state.runningLeafPosition, 0);
        assertEq(tournament.getMatchAdvancedCount(), 1);
    }
}

contract SealLeafMatchGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _leafMatchFixture(CommitmentShape.SECOND_DIFFERENT);
        _advanceToSealable(LEAF_HEIGHT, CommitmentShape.SECOND_DIFFERENT);
    }

    function testMeasureChargedFullProofLeafSealAtPositionOne() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        Measurement memory result =
            _measure(_sealCall(true), Gas.SEAL_LEAF_MATCH);
        _logMeasurement("seal leaf match", result);
        _assertCalibratedAllocation(result, Gas.SEAL_LEAF_MATCH);

        Match.Id memory id = matchId;
        Match.State memory state = tournament.getMatch(Match.hashFromId(id));
        assertTrue(Match.isSealed(state));
        assertEq(state.runningLeafPosition, 1);
    }
}

contract SealLeafMatchLeftGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _leafMatchFixture(CommitmentShape.THIRD_DIFFERENT);
        _advanceToSealable(LEAF_HEIGHT, CommitmentShape.THIRD_DIFFERENT);
    }

    function testMeasureChargedFullProofLeftLeafSealAtPositionTwo() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        Measurement memory result =
            _measure(_sealCall(true), Gas.SEAL_LEAF_MATCH);
        _logMeasurement("seal leaf match left", result);
        _assertReviewedHeadroom(result, Gas.SEAL_LEAF_MATCH);

        Match.State memory state =
            tournament.getMatch(Match.hashFromId(matchId));
        assertTrue(Match.isSealed(state));
        assertEq(state.runningLeafPosition, 2);
    }
}

contract SealInnerMatchGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.SECOND_DIFFERENT);
        _advanceToSealable(ROOT_HEIGHT, CommitmentShape.SECOND_DIFFERENT);
    }

    function testMeasureChargedFullProofInnerSealAtPositionOne() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        Measurement memory result = _measure(
            _sealCall(false), Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
        );
        _logMeasurement("seal inner match", result);
        _assertCalibratedAllocation(
            result, Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
        );

        Match.Id memory id = matchId;
        Match.State memory state = tournament.getMatch(Match.hashFromId(id));
        assertTrue(Match.isSealed(state));
        assertEq(state.runningLeafPosition, 1);
        assertEq(tournament.getNewInnerTournamentCount(), 1);
    }
}

contract SealInnerMatchLeftGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.THIRD_DIFFERENT);
        _advanceToSealable(ROOT_HEIGHT, CommitmentShape.THIRD_DIFFERENT);
    }

    function testMeasureChargedFullProofLeftInnerSealAtPositionTwo() public {
        vm.roll(uint256(START_BLOCK) + MATCH_EFFORT + 1);
        Measurement memory result = _measure(
            _sealCall(false), Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
        );
        _logMeasurement("seal inner match left", result);
        _assertReviewedHeadroom(
            result, Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
        );

        Match.State memory state =
            tournament.getMatch(Match.hashFromId(matchId));
        assertTrue(Match.isSealed(state));
        assertEq(state.runningLeafPosition, 2);
        assertEq(tournament.getNewInnerTournamentCount(), 1);
    }
}

// Each scenario uses its own contract so Foundry constructs the fixture in a
// separate setUp transaction and the measured tournament accesses remain cold.
contract ActiveOneWinsTimeoutGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.RIGHTMOST_DIFFERENT);
        _advance(tournament, matchId, CommitmentShape.SAME, ROOT_HEIGHT);
        _assertNonzeroMatchPosition();
        _addDangling(CommitmentShape.FIRST_DIFFERENT, CLAIMER_C);
        resolutionBlock =
            _deadlinePlus(rightmostNode(ROOT_HEIGHT), TIMEOUT_OVERDUE);
    }

    function testMeasureChargedOneWinsAndRepairsMatch() public {
        _measureTimeoutWinner(
            "active one wins timeout",
            CommitmentShape.SAME,
            ROOT_HEIGHT,
            MAX_ALLOWANCE - TIMEOUT_OVERDUE
        );
    }
}

contract ActiveTwoWinsTimeoutGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.RIGHTMOST_DIFFERENT);
        _advance(tournament, matchId, CommitmentShape.SAME, ROOT_HEIGHT);
        _advance(
            tournament,
            matchId,
            CommitmentShape.RIGHTMOST_DIFFERENT,
            ROOT_HEIGHT - 1
        );
        _assertNonzeroMatchPosition();
        _addDangling(CommitmentShape.FIRST_DIFFERENT, CLAIMER_C);
        resolutionBlock = _deadlinePlus(sameNode(ROOT_HEIGHT), TIMEOUT_OVERDUE);
    }

    function testMeasureChargedTwoWinsAndRepairsMatch() public {
        _measureTimeoutWinner(
            "active two wins timeout",
            CommitmentShape.RIGHTMOST_DIFFERENT,
            ROOT_HEIGHT,
            MAX_ALLOWANCE - TIMEOUT_OVERDUE
        );
    }
}

contract SealedLeafOneWinsTimeoutGasTest is TournamentGasTest {
    function setUp() public {
        _initializeSealedLeafTimeoutFixture(ShortSide.TWO, true);
        resolutionBlock =
            _deadlinePlus(secondDifferentNode(LEAF_HEIGHT), TIMEOUT_OVERDUE);
    }

    function testMeasureChargedOneWinsAndRepairsMatch() public {
        _measureTimeoutWinner(
            "sealed leaf one wins timeout",
            CommitmentShape.SAME,
            LEAF_HEIGHT,
            CLOCK_CHARGE - 2 * TIMEOUT_OVERDUE
        );
    }
}

contract SealedLeafTwoWinsTimeoutGasTest is TournamentGasTest {
    function setUp() public {
        _initializeSealedLeafTimeoutFixture(ShortSide.ONE, true);
        resolutionBlock = _deadlinePlus(sameNode(LEAF_HEIGHT), TIMEOUT_OVERDUE);
    }

    function testMeasureChargedTwoWinsAndRepairsMatch() public {
        Measurement memory result = _measureTimeoutWinner(
            "sealed leaf two wins timeout",
            CommitmentShape.SECOND_DIFFERENT,
            LEAF_HEIGHT,
            CLOCK_CHARGE - 2 * TIMEOUT_OVERDUE
        );
        _assertCalibratedAllocation(result, Gas.WIN_MATCH_BY_TIMEOUT);
    }
}

contract ActiveAdvancedEliminationGasTest is TournamentGasTest {
    function setUp() public {
        _initializeFixture();
        _rootMatchFixture(CommitmentShape.RIGHTMOST_DIFFERENT);
        _advance(tournament, matchId, CommitmentShape.SAME, ROOT_HEIGHT);
        _assertNonzeroMatchPosition();
        resolutionBlock = _activeDoubleEliminationBlock(
            rightmostNode(ROOT_HEIGHT), sameNode(ROOT_HEIGHT)
        );
    }

    function testMeasureEqualityEliminatesBoth() public {
        _measureTimeoutElimination("active advanced timeout elimination");
    }
}

contract SealedLeafEliminationGasTest is TournamentGasTest {
    function setUp() public {
        _initializeSealedLeafTimeoutFixture(ShortSide.TWO, false);
        resolutionBlock = _leafRaceDoubleEliminationBlock(
            sameNode(LEAF_HEIGHT), secondDifferentNode(LEAF_HEIGHT)
        );

        (Clock.State memory clockOne,) =
            tournament.getCommitment(sameNode(LEAF_HEIGHT));
        (Clock.State memory clockTwo,) =
            tournament.getCommitment(secondDifferentNode(LEAF_HEIGHT));
        assertGt(
            Time.Duration.unwrap(clockOne.allowance),
            Time.Duration.unwrap(clockTwo.allowance)
        );
        assertLe(resolutionBlock, type(uint64).max);
        Time.Instant boundary = Time.Instant.wrap(uint64(resolutionBlock));
        assertEq(
            Time.Duration.unwrap(Clock.remainingAt(clockOne, boundary)),
            Time.Duration.unwrap(Clock.overdueByAt(clockTwo, boundary))
        );
        assertEq(Time.Duration.unwrap(Clock.remainingAt(clockTwo, boundary)), 0);
    }

    function testMeasureEqualityEliminatesBoth() public {
        Measurement memory result =
            _measureTimeoutElimination("sealed leaf timeout elimination");
        _assertCalibratedAllocation(result, Gas.ELIMINATE_MATCH_BY_TIMEOUT);
    }
}

contract InnerOneWinsGasTest is TournamentGasTest {
    function setUp() public {
        _initializeResolvedInnerWinnerFixture(
            CommitmentShape.SAME, CommitmentShape.SAME, true
        );
    }

    function testMeasureOneWinsAndRepairsMatch() public {
        _measureInnerWinner("inner one wins", CommitmentShape.SAME);
    }
}

contract InnerTwoWinsGasTest is TournamentGasTest {
    function setUp() public {
        _initializeResolvedInnerWinnerFixture(
            CommitmentShape.RIGHTMOST_DIFFERENT,
            CommitmentShape.SECOND_DIFFERENT,
            true
        );
    }

    function testMeasureTwoWinsAndRepairsMatch() public {
        Measurement memory result = _measureInnerWinner(
            "inner two wins", CommitmentShape.SECOND_DIFFERENT
        );
        _assertCalibratedAllocation(result, Gas.WIN_INNER_TOURNAMENT);
    }
}

contract InnerEliminationGasTest is TournamentGasTest {
    function setUp() public {
        _initializeResolvedInnerWinnerFixture(
            CommitmentShape.SAME, CommitmentShape.SAME, false
        );
        resolutionBlock = childEliminationBlock;
        vm.roll(resolutionBlock);
        assertTrue(childTournament.canBeEliminated());
    }

    function testMeasureExpiredWinnerEliminatesParentMatch() public {
        Measurement memory result =
            _measureInnerElimination("inner elimination");
        _assertCalibratedAllocation(result, Gas.ELIMINATE_INNER_TOURNAMENT);
    }
}

contract InnerSingleClaimTwoWinsGasTest is TournamentGasTest {
    function setUp() public {
        _initializeSingleClaimInnerWinnerFixture(
            CommitmentShape.RIGHTMOST_DIFFERENT,
            CommitmentShape.SECOND_DIFFERENT,
            true
        );
    }

    function testMeasureSingleClaimWinnerRepairsMatch() public {
        _measureInnerWinner(
            "inner single-claim two wins", CommitmentShape.SECOND_DIFFERENT
        );
    }
}

contract InnerSingleClaimEliminationGasTest is TournamentGasTest {
    function setUp() public {
        _initializeSingleClaimInnerWinnerFixture(
            CommitmentShape.SAME, CommitmentShape.SAME, false
        );
        resolutionBlock = childEliminationBlock;
        vm.roll(resolutionBlock);
        assertTrue(childTournament.canBeEliminated());
    }

    function testMeasureSingleClaimWinnerExpires() public {
        _measureInnerElimination("inner single-claim elimination");
    }
}

contract InnerNoWinnerEliminationGasTest is TournamentGasTest {
    function setUp() public {
        _initializeNoWinnerInnerEliminationFixture();
    }

    function testMeasureNoWinnerEliminatesParentMatch() public {
        _measureInnerElimination("inner no-winner elimination");
    }
}
