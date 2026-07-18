// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

pragma solidity ^0.8.0;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {ITournament} from "src/ITournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "../Util.sol";
import {
    HistoricalThreeLevelGeometry as HistoricalGeometry
} from "../fixtures/HistoricalThreeLevelGeometry.sol";

contract HistoricalThreeLevelInnerTest is Util {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable FACTORY;
    ITournament topTournament;
    ITournament middleTournament;

    // Player accounts for testing
    address player0 = vm.addr(1);
    address player1 = vm.addr(2);

    constructor() {
        (FACTORY,) = Util.instantiateHistoricalThreeLevelTournamentFactory();
    }

    receive() external payable {}

    function testInnerEliminationEventuallyAllowedAfterFinish() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // Create middle tournament via top seal
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.historicalMatchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        uint256 _playerToSeal =
            Util.advanceMatch(topTournament, _matchId, _opponent);
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.assertEventCountersEqualZero(middleTournament);

        // Only player 0 joins middle; let it finish by timeout (no matches occur)
        Util.joinTournament(middleTournament, 0);

        // Roll far enough so the middle tournament is almost closed
        assertFalse(middleTournament.isClosed(), "should not be closed yet");
        assertFalse(middleTournament.isFinished(), "should not be finished yet");
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE) - 1);
        assertFalse(middleTournament.isClosed(), "should not be closed yet");
        assertFalse(middleTournament.isFinished(), "should not be finished yet");

        // One more block: close
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(middleTournament.isClosed(), "should be closed");
        assertTrue(middleTournament.isFinished(), "should be finished");

        // Tournament finished but not yet eliminable since a winner exists
        assertFalse(
            middleTournament.canBeEliminated(), "should not be eliminable yet"
        );

        // Identify winner commitment and its paused allowance
        (bool _finished,, Tree.Node _winner,) =
            middleTournament.innerTournamentWinner();
        assertTrue(_finished, "inner should report finished");
        (Clock.State memory wc,) = middleTournament.getCommitment(_winner);

        // Move close to allowance window: still not eliminable
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(wc.allowance) - 1);
        assertFalse(middleTournament.canBeEliminated(), "still not eliminable");

        // One more block: eliminable
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(middleTournament.canBeEliminated(), "now eliminable");
    }

    function setUp() public {}

    function assertNoElimination() internal {
        assertFalse(middleTournament.canBeEliminated(), "can be eliminated");
        vm.expectRevert(ITournament.ChildTournamentCannotBeEliminated.selector);
        topTournament.eliminateInnerTournament(middleTournament);
    }

    function testInnerWinner() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 1 joins tournament
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.historicalMatchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        uint256 _playerToSeal =
            Util.advanceMatch(topTournament, _matchId, _opponent);

        // expect new inner created
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(_entries[0].topics[0], ITournament.NewInnerTournament.selector);
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        (bool _finished, Tree.Node _winner,,) =
            middleTournament.innerTournamentWinner();
        assertFalse(_finished, "winner should be zero node");

        assertNoElimination();

        // Player 0 should win after the inner tournament finishes.
        uint256 _t = vm.getBlockNumber();
        uint256 _rootTournamentFinish = _t + Time.Duration.unwrap(MAX_ALLOWANCE);
        uint256 player0BalanceBefore = player0.balance;
        uint256 tournamentBalanceBefore = address(middleTournament).balance;

        Util.joinTournament(middleTournament, 0);

        uint256 player0BalanceAfter = player0.balance;
        uint256 tournamentBalanceAfter = address(middleTournament).balance;
        uint256 bondAmount = middleTournament.bondValue();
        assertEq(
            player0BalanceBefore - bondAmount,
            player0BalanceAfter,
            "Player 0 should have paid bond"
        );
        assertEq(
            tournamentBalanceBefore, 0, "Tournament should have no balance"
        );
        assertEq(
            tournamentBalanceAfter, bondAmount, "Tournament should have bond"
        );

        // Try to recover bond before tournament is finished - should fail
        vm.expectRevert(ITournament.TournamentNotFinished.selector);
        middleTournament.tryRecoveringBond();

        vm.roll(_rootTournamentFinish);
        (_finished, _winner,,) = middleTournament.innerTournamentWinner();
        // Recovery is permissionless and may precede parent propagation.
        assertTrue(middleTournament.tryRecoveringBond());
        Util.winInnerTournament(
            topTournament,
            middleTournament,
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 1]
        );
        assertEq(player0.balance, player0BalanceAfter + tournamentBalanceAfter);
        assertEq(
            address(middleTournament).balance,
            0,
            "Tournament should have no balance"
        );

        {
            (
                bool _finishedTop,
                Tree.Node _commitment,
                Machine.Hash _finalState
            ) = topTournament.arbitrationResult();

            uint256 _winnerPlayer = 0;
            assertTrue(
                _commitment.eq(
                    playerNodes[_winnerPlayer][HistoricalGeometry.height(0)]
                ),
                "winner should be player 0"
            );
            assertTrue(_finishedTop, "tournament should be finished");
            assertTrue(
                _finalState.eq(Util.finalStates[_winnerPlayer]),
                "final state should match"
            );
        }

        //create another tournament for other test
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 1 joins tournament
        _height = 0;
        Util.joinTournament(topTournament, _opponent);

        _matchId = Util.historicalMatchId(_opponent, _height);
        _match = topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal = Util.advanceMatch(topTournament, _matchId, _opponent);

        // expect new inner created
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(_entries[0].topics[0], ITournament.NewInnerTournament.selector);
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        (_finished, _winner,,) = middleTournament.innerTournamentWinner();
        assertTrue(_winner.isZero(), "winner should be zero node");

        _t = vm.getBlockNumber();
        _rootTournamentFinish = _t + Time.Duration.unwrap(MAX_ALLOWANCE);
        uint256 _middleTournamentFinish = _rootTournamentFinish;

        player0BalanceBefore = player0.balance;
        Util.joinTournament(middleTournament, 0);

        //let player 1 join, then timeout player 0
        Util.joinTournament(middleTournament, _opponent);

        (Clock.State memory _player0Clock,) = middleTournament.getCommitment(
            playerNodes[0][HistoricalGeometry.height(_height)]
        );
        _matchId = Util.historicalMatchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        vm.expectRevert(ITournament.NeitherClockHasTimedOut.selector);
        middleTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][HistoricalGeometry.height(1) - 1],
            playerNodes[1][HistoricalGeometry.height(1) - 1]
        );

        vm.roll(
            Time.Instant
                .unwrap(_player0Clock.startInstant.add(_player0Clock.allowance))
        );
        assertNoElimination();

        vm.startPrank(player1);
        Util.winMatchByTimeout(
            middleTournament,
            _matchId,
            playerNodes[1][HistoricalGeometry.height(1) - 1],
            playerNodes[1][HistoricalGeometry.height(1) - 1]
        );
        vm.stopPrank();

        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertFalse(_match.exists(), "match should be deleted");

        assertNoElimination();
        vm.roll(_middleTournamentFinish);
        assertNoElimination();

        (_finished, _winner,,) = middleTournament.innerTournamentWinner();
        uint256 player1BalanceBeforeRecovery = player1.balance;
        uint256 tournamentBalanceBeforeRecovery =
            address(middleTournament).balance;
        uint256 burnedBalanceBefore = address(0).balance;
        assertGe(tournamentBalanceBeforeRecovery, bondAmount);

        Util.winInnerTournament(
            topTournament,
            middleTournament,
            playerNodes[1][HistoricalGeometry.height(0) - 1],
            playerNodes[1][HistoricalGeometry.height(0) - 1]
        );

        assertEq(
            player0.balance,
            player0BalanceBefore - bondAmount,
            "Player 0 should have cost one bond"
        );
        assertEq(
            player1.balance,
            player1BalanceBeforeRecovery + bondAmount,
            "Player 1 should have recovered one bond"
        );
        assertEq(
            address(0).balance,
            burnedBalanceBefore + tournamentBalanceBeforeRecovery - bondAmount,
            "Residual child balance should have been burned"
        );
        assertEq(
            address(middleTournament).balance,
            0,
            "Tournament should have no balance"
        );

        {
            vm.roll(_rootTournamentFinish);
            (
                bool _finishedTop,
                Tree.Node _commitment,
                Machine.Hash _finalState
            ) = topTournament.arbitrationResult();

            uint256 _winnerPlayer = 1;
            assertTrue(
                _commitment.eq(
                    playerNodes[_winnerPlayer][HistoricalGeometry.height(0)]
                ),
                "winner should be player 1"
            );
            assertTrue(_finishedTop, "tournament should be finished");
            assertTrue(
                _finalState.eq(Util.finalStates[_winnerPlayer]),
                "final state should match"
            );
        }
    }

    function testInnerNoWinnerNoWinner() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        Util.joinTournament(topTournament, 1);
        Match.Id memory _matchId = Util.historicalMatchId(1, 0);
        uint256 _playerToSeal = Util.advanceMatch(topTournament, _matchId, 1);

        // expect new inner created
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        assertNoElimination();
        uint256 _t = vm.getBlockNumber();
        uint256 _middleTournamentFinish =
            _t + Time.Duration.unwrap(MAX_ALLOWANCE);
        vm.roll(_middleTournamentFinish - 1);
        assertNoElimination();

        vm.roll(_middleTournamentFinish);
        assertTrue(middleTournament.canBeEliminated(), "can't be eliminated");
        Util.eliminateInnerTournament(topTournament, middleTournament);

        vm.expectRevert();
        topTournament.arbitrationResult();
    }

    function testInnerNoWinner() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        Util.joinTournament(topTournament, 1);
        Util.joinTournament(topTournament, 2);

        Match.Id memory _matchId = Util.historicalMatchId(1, 0);
        uint256 _playerToSeal = Util.advanceMatch(topTournament, _matchId, 1);

        // expect new inner created
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        assertNoElimination();
        uint256 _t = vm.getBlockNumber();
        uint256 _middleTournamentFinish =
            _t + Time.Duration.unwrap(MAX_ALLOWANCE);
        vm.roll(_middleTournamentFinish - 1);
        assertNoElimination();

        vm.roll(_middleTournamentFinish);
        assertTrue(middleTournament.canBeEliminated(), "can't be eliminated");
        Util.eliminateInnerTournament(topTournament, middleTournament);

        (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState) =
            topTournament.arbitrationResult();
        assertTrue(_finishedTop, "game not finished");
        assertTrue(
            _commitment.eq(Util.playerNodes[2][HistoricalGeometry.height(0)]),
            "wrong winner commitment"
        );
        assertTrue(_finalState.eq(Util.finalStates[2]), "wrong final state");
    }

    function testInnerWinnerTimeoutClosed() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        Util.joinTournament(topTournament, 1);
        Util.joinTournament(topTournament, 2);

        Match.Id memory _matchId = Util.historicalMatchId(1, 0);
        uint256 _playerToSeal = Util.advanceMatch(topTournament, _matchId, 1);

        // expect new inner created
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));
        assertNoElimination();

        Util.joinTournament(middleTournament, 0);

        assertFalse(middleTournament.isClosed());
        (bool hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertFalse(hasWinner);

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));
        assertTrue(middleTournament.isClosed());
        (hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertTrue(hasWinner);
        assertNoElimination();

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE) - 1);
        assertNoElimination();
        vm.roll(vm.getBlockNumber() + 1);

        assertTrue(middleTournament.canBeEliminated(), "can't be eliminated");
        Util.eliminateInnerTournament(topTournament, middleTournament);

        (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState) =
            topTournament.arbitrationResult();
        assertTrue(_finishedTop, "game not finished");
        assertTrue(
            _commitment.eq(Util.playerNodes[2][HistoricalGeometry.height(0)]),
            "wrong winner commitment"
        );
        assertTrue(_finalState.eq(Util.finalStates[2]), "wrong final state");
    }

    function testInnerWinnerTimeoutAllowance() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        Util.joinTournament(topTournament, 1);
        Util.joinTournament(topTournament, 2);

        Match.Id memory _matchId = Util.historicalMatchId(1, 0);
        uint256 _playerToSeal = Util.advanceMatch(topTournament, _matchId, 1);

        // expect new inner created
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));
        assertNoElimination();

        Util.joinTournament(middleTournament, 0);
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MATCH_EFFORT) + 3);
        Util.joinTournament(middleTournament, 1);
        (Clock.State memory lateClock,) = middleTournament.getCommitment(
            playerNodes[1][HistoricalGeometry.height(1)]
        );
        assertEq(
            Time.Duration.unwrap(lateClock.allowance),
            Time.Duration.unwrap(MAX_ALLOWANCE)
                - Time.Duration.unwrap(MATCH_EFFORT) - 3
        );
        middleTournament.advanceMatch(
            Util.historicalMatchId(1, 1),
            playerNodes[0][HistoricalGeometry.height(1) - 1],
            playerNodes[0][HistoricalGeometry.height(1) - 1],
            playerNodes[0][HistoricalGeometry.height(1) - 2],
            playerNodes[0][HistoricalGeometry.height(1) - 2]
        );

        assertFalse(middleTournament.isClosed());
        (bool hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertFalse(hasWinner);

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE) - 3);

        assertTrue(middleTournament.isClosed());
        (hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertFalse(hasWinner);
        assertNoElimination();

        Util.winMatchByTimeout(
            middleTournament,
            Util.historicalMatchId(1, 1),
            playerNodes[0][HistoricalGeometry.height(1) - 1],
            playerNodes[0][HistoricalGeometry.height(1) - 1]
        );

        Clock.State memory winningClock;
        (hasWinner,,, winningClock) = middleTournament.innerTournamentWinner();
        assertTrue(hasWinner);
        assertEq(
            Time.Duration.unwrap(winningClock.allowance),
            Time.Duration.unwrap(MAX_ALLOWANCE)
                - Time.Duration.unwrap(MATCH_EFFORT)
        );
        assertNoElimination();

        vm.roll(
            vm.getBlockNumber() + Time.Duration.unwrap(winningClock.allowance)
                - 1
        );
        assertNoElimination();
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(middleTournament.canBeEliminated(), "can't be eliminated");

        vm.txGasPrice(2);
        uint256 callerBalanceBefore = address(this).balance;
        uint256 tournamentBalanceBefore = address(topTournament).balance;

        Util.eliminateInnerTournament(topTournament, middleTournament);

        uint256 callerBalanceAfter = address(this).balance;
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have earned profit"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tounament should have paid gas"
        );

        (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState) =
            topTournament.arbitrationResult();
        assertTrue(_finishedTop, "game not finished");
        assertTrue(
            _commitment.eq(playerNodes[2][HistoricalGeometry.height(0)]),
            "wrong winner commitment"
        );
        assertTrue(_finalState.eq(Util.finalStates[2]), "wrong final state");
    }

    function testInnerFairDeduction() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        uint64 joinDelay = 3;
        vm.roll(vm.getBlockNumber() + joinDelay);
        Util.joinTournament(topTournament, 1);
        Util.joinTournament(topTournament, 2);

        Match.Id memory _matchId = Util.historicalMatchId(1, 0);
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MATCH_EFFORT) + 7);
        uint256 _playerToSeal = Util.advanceMatch(topTournament, _matchId, 1);

        // expect new inner created
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));
        ITournament.TournamentArguments memory childArgs =
            middleTournament.tournamentArguments();
        (Clock.State memory parentClockOne,) =
            topTournament.getCommitment(_matchId.commitmentOne);
        (Clock.State memory parentClockTwo,) =
            topTournament.getCommitment(_matchId.commitmentTwo);
        uint64 parentAllowanceOne =
            Time.Duration.unwrap(parentClockOne.allowance);
        uint64 parentAllowanceTwo =
            Time.Duration.unwrap(parentClockTwo.allowance);
        uint64 delegatedAllowance = parentAllowanceOne > parentAllowanceTwo
            ? parentAllowanceOne
            : parentAllowanceTwo;
        assertEq(Time.Duration.unwrap(childArgs.allowance), delegatedAllowance);
        assertLe(delegatedAllowance, Time.Duration.unwrap(MAX_ALLOWANCE));
        assertEq(
            delegatedAllowance, Time.Duration.unwrap(MAX_ALLOWANCE) - joinDelay
        );
        assertNoElimination();

        Util.joinTournament(middleTournament, 0);
        Util.joinTournament(middleTournament, 1);

        assertFalse(middleTournament.isClosed());
        (bool hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertFalse(hasWinner);

        vm.roll(vm.getBlockNumber() + delegatedAllowance - 1);
        vm.expectRevert(ITournament.NeitherClockHasTimedOut.selector);
        middleTournament.winMatchByTimeout(
            Util.historicalMatchId(1, 1),
            playerNodes[0][HistoricalGeometry.height(1) - 1],
            playerNodes[0][HistoricalGeometry.height(1) - 1]
        );

        vm.roll(vm.getBlockNumber() + 1);

        assertTrue(middleTournament.isClosed());
        (hasWinner,,,) = middleTournament.innerTournamentWinner();
        assertFalse(hasWinner);
        assertNoElimination();

        Util.winMatchByTimeout(
            middleTournament,
            Util.historicalMatchId(1, 1),
            playerNodes[1][HistoricalGeometry.height(1) - 1],
            playerNodes[1][HistoricalGeometry.height(1) - 1]
        );

        Clock.State memory winnerAtFinish;
        (hasWinner,,, winnerAtFinish) = middleTournament.innerTournamentWinner();
        assertTrue(hasWinner);
        assertNoElimination();

        vm.roll(
            vm.getBlockNumber() + Time.Duration.unwrap(winnerAtFinish.allowance)
                - 1
        );
        assertNoElimination();

        vm.txGasPrice(2);
        uint256 callerBalanceBefore = address(this).balance;
        uint256 tournamentBalanceBefore = address(topTournament).balance;
        Clock.State memory returnedClock;
        (hasWinner,,, returnedClock) = middleTournament.innerTournamentWinner();
        assertTrue(hasWinner);
        assertTrue(returnedClock.startInstant.isZero());
        assertLe(
            Time.Duration.unwrap(returnedClock.allowance), delegatedAllowance
        );

        // win at the last second
        Util.winInnerTournament(
            topTournament,
            middleTournament,
            playerNodes[1][HistoricalGeometry.height(0) - 1],
            playerNodes[1][HistoricalGeometry.height(0) - 1]
        );
        (Clock.State memory propagatedClock,) =
            topTournament.getCommitment(_matchId.commitmentTwo);
        assertEq(
            Time.Duration.unwrap(propagatedClock.allowance),
            Time.Duration.unwrap(returnedClock.allowance)
        );
        assertTrue(propagatedClock.startInstant.isZero());

        uint256 callerBalanceAfter = address(this).balance;
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have earned profit"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tounament should have paid gas"
        );

        (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState) =
            topTournament.arbitrationResult();
        assertFalse(_finishedTop, "game finished");

        Match.Id memory topMatch = Match.Id(
            playerNodes[2][HistoricalGeometry.height(0)],
            playerNodes[1][HistoricalGeometry.height(0)]
        );

        topTournament.advanceMatch(
            topMatch,
            // player 2 bisection is weird
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[2][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 2],
            playerNodes[0][HistoricalGeometry.height(0) - 2]
        );

        (Clock.State memory finalRunningClock,) = topTournament.getCommitment(
            playerNodes[1][HistoricalGeometry.height(0)]
        );
        assertFalse(finalRunningClock.startInstant.isZero());
        vm.roll(
            Time.Instant
                .unwrap(
                    finalRunningClock.startInstant
                        .add(
                            Time.Duration
                                .wrap(
                                    Time.Duration
                                        .unwrap(finalRunningClock.allowance) - 1
                                )
                        )
                )
        );
        vm.expectRevert(ITournament.NeitherClockHasTimedOut.selector);
        topTournament.winMatchByTimeout(
            topMatch,
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[2][HistoricalGeometry.height(0) - 1]
        );

        vm.roll(vm.getBlockNumber() + 1);
        Util.winMatchByTimeout(
            topTournament,
            topMatch,
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[2][HistoricalGeometry.height(0) - 1]
        );

        (_finishedTop, _commitment, _finalState) =
            topTournament.arbitrationResult();
        assertTrue(_finishedTop, "game not finished");
        assertTrue(
            _commitment.eq(playerNodes[2][HistoricalGeometry.height(0)]),
            "wrong winner commitment"
        );
        assertTrue(_finalState.eq(Util.finalStates[2]), "wrong final state");
    }
}
