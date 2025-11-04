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

import {ITournament} from "src/ITournament.sol";
import {
    ArbitrationConstants
} from "src/arbitration-config/ArbitrationConstants.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";

contract TournamentTest is Util {
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

    event MatchCreated(
        Match.IdHash indexed matchIdHash,
        Tree.Node indexed one,
        Tree.Node indexed two,
        Tree.Node leftOfTwo
    );

    constructor() {
        (FACTORY,) = Util.instantiateTournamentFactory();
    }

    receive() external payable {}

    function testJoinTournament() public {
        uint256 player0BalanceBefore = player0.balance;
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        uint256 player0BalanceAfter = player0.balance;
        uint256 bondAmount = topTournament.bondValue();
        assertEq(
            player0BalanceBefore - bondAmount,
            player0BalanceAfter,
            "Player 0 should have paid bond"
        );

        // player 1 joins tournament
        uint256 _opponent = 1;
        // pair commitment, expect a match
        vm.expectEmit(true, true, false, true, address(topTournament));
        emit MatchCreated(
            Util.matchId(_opponent, 0).hashFromId(),
            playerNodes[0][ArbitrationConstants.height(0)],
            playerNodes[1][ArbitrationConstants.height(0)],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
        );

        uint256 player1BalanceBefore = player1.balance;
        Util.joinTournament(topTournament, _opponent);
        uint256 player1BalanceAfter = player1.balance;
        assertEq(
            player1BalanceBefore - bondAmount,
            player1BalanceAfter,
            "Player 1 should have paid bond"
        );
    }

    function testJoinTournamentInsufficientBond(uint256 insufficientBond)
        public
    {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        insufficientBond =
            bound(insufficientBond, 0, topTournament.bondValue() - 1);

        // Try to join with insufficient bond - should fail
        (,,, uint64 height) = topTournament.tournamentLevelConstants();
        Tree.Node _left = playerNodes[1][height - 1];
        Tree.Node _right = playerNodes[1][height - 1];
        Machine.Hash _finalState = TWO_STATE;

        vm.expectRevert(ITournament.InsufficientBond.selector);
        topTournament.joinTournament{value: insufficientBond}(
            _finalState, generateFinalStateProof(1, height), _left, _right
        );
    }

    // function testDuplicateJoinTournament() public {
    //     topTournament = Util.initializePlayer0Tournament(FACTORY);

    //     // duplicate commitment should be reverted
    //     vm.expectRevert("clock is initialized");
    //     Util.joinTournament(topTournament, 0);
    // }

    function testTimeout() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _tournamentFinishWithMatch = _t
            + Time.Duration.unwrap(MAX_ALLOWANCE)
            + Time.Duration.unwrap(MATCH_EFFORT);

        // player 1 joins tournament
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.matchId(_opponent, _height);
        assertFalse(
            topTournament.canWinMatchByTimeout(_matchId),
            "shouldn't be able to win match by timeout"
        );

        // player 1 should win after fast forward time to player 0 timeout
        // player 0 timeout first because he's supposed to advance match first after the match is created
        (Clock.State memory _player0Clock,) = topTournament.getCommitment(
            playerNodes[0][ArbitrationConstants.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player0Clock.startInstant.add(_player0Clock.allowance))
        );
        assertTrue(
            topTournament.canWinMatchByTimeout(_matchId),
            "should be able to win match by timeout"
        );

        uint256 tournamentBalanceBefore = address(topTournament).balance;
        uint256 callerBalanceBefore = player0.balance;
        vm.txGasPrice(2);
        vm.prank(player0);
        topTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][ArbitrationConstants.height(0) - 1],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
        );
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        uint256 callerBalanceAfter = player0.balance;

        uint256 bondAmount = topTournament.bondValue();
        assertEq(
            tournamentBalanceBefore,
            2 * bondAmount,
            "tournament balance should be 2 * bond amount initially"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tournament balance should be less than before"
        );
        // the caller should have received refund from the gas spent and profit
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller balance should be greater than before"
        );

        vm.roll(_tournamentFinishWithMatch);
        (bool _finished, Tree.Node _winner, Machine.Hash _finalState) =
            topTournament.arbitrationResult();

        uint256 _winnerPlayer = 1;
        assertTrue(
            _winner.eq(
                playerNodes[_winnerPlayer][ArbitrationConstants.height(0)]
            ),
            "winner should be player 1"
        );
        assertTrue(_finished, "tournament should be finished");
        assertTrue(
            _finalState.eq(Util.finalStates[_winnerPlayer]),
            "final state should match"
        );

        topTournament = Util.initializePlayer0Tournament(FACTORY);
        _t = vm.getBlockNumber();

        // the delay is increased when a match is created
        _tournamentFinishWithMatch = _t + Time.Duration.unwrap(MAX_ALLOWANCE)
            + Time.Duration.unwrap(MATCH_EFFORT);

        // player 1 joins tournament
        Util.joinTournament(topTournament, _opponent);

        // player 0 should win after fast forward time to player 1 timeout
        // player 1 timeout first because he's supposed to advance match after player 0 advanced
        _matchId = Util.matchId(_opponent, _height);

        callerBalanceBefore = address(this).balance;
        tournamentBalanceBefore = address(topTournament).balance;
        topTournament.advanceMatch(
            _matchId,
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 2],
            playerNodes[0][ArbitrationConstants.height(0) - 2]
        );
        callerBalanceAfter = address(this).balance;
        tournamentBalanceAfter = address(topTournament).balance;
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

        (Clock.State memory _player1Clock,) = topTournament.getCommitment(
            playerNodes[1][ArbitrationConstants.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player1Clock.startInstant.add(_player1Clock.allowance))
        );
        assertTrue(
            topTournament.canWinMatchByTimeout(_matchId),
            "should be able to win match by timeout"
        );

        topTournament.winMatchByTimeout(
            _matchId,
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 1]
        );

        vm.roll(_tournamentFinishWithMatch);
        (_finished, _winner, _finalState) = topTournament.arbitrationResult();

        _winnerPlayer = 0;
        assertTrue(
            _winner.eq(
                playerNodes[_winnerPlayer][ArbitrationConstants.height(0)]
            ),
            "winner should be player 0"
        );
        assertTrue(_finished, "tournament should be finished");
        assertTrue(
            _finalState.eq(Util.finalStates[_winnerPlayer]),
            "final state should match"
        );
    }

    function testEliminateByTimeout() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 1 joins tournament
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.matchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _rootTournamentFinish =
            _t + 2 * Time.Duration.unwrap(MAX_ALLOWANCE);

        vm.roll(_rootTournamentFinish - 1);
        // cannot eliminate match when both blocks still have time
        vm.expectRevert(ITournament.BothClocksHaveNotTimedOut.selector);
        topTournament.eliminateMatchByTimeout(_matchId);

        vm.roll(_rootTournamentFinish);

        uint256 tournamentBalanceBefore = address(topTournament).balance;
        uint256 callerBalanceBefore = address(this).balance;
        topTournament.eliminateMatchByTimeout(_matchId);
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        uint256 callerBalanceAfter = address(this).balance;

        uint256 bondAmount = topTournament.bondValue();
        assertEq(tournamentBalanceBefore, 2 * bondAmount);
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tournament should have paid gas"
        );
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have earned profit"
        );
    }

    function testWinByTimeoutWrongChildrenReverts() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.matchId(_opponent, _height);

        // Let commitmentOne time out (player 0), then attempt with wrong children
        (Clock.State memory _player0Clock,) = topTournament.getCommitment(
            playerNodes[0][ArbitrationConstants.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player0Clock.startInstant.add(_player0Clock.allowance))
        );

        vm.expectRevert();
        topTournament.winMatchByTimeout(
            _matchId,
            // wrong child nodes for commitmentTwo
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 1]
        );

        // Correct children should succeed
        topTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][ArbitrationConstants.height(0) - 1],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
        );
    }
}
