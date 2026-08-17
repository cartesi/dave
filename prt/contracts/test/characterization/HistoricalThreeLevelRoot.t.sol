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

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "../Util.sol";
import {HistoricalThreeLevelGeometry as HistoricalGeometry} from "../fixtures/HistoricalThreeLevelGeometry.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

contract ConfigurableBondReceiver {
    bool public rejectsPayment = true;

    function acceptPayments() external {
        rejectsPayment = false;
    }

    receive() external payable {
        require(!rejectsPayment);
    }
}

contract HistoricalThreeLevelRootTest is Util {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable FACTORY;
    ITournament topTournament;

    constructor() {
        (FACTORY,) = Util.instantiateHistoricalThreeLevelTournamentFactory();
    }

    function testRootWinner() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // no winner before tournament finished
        (bool _finished, Tree.Node _winner, Machine.Hash _finalState) =
            topTournament.arbitrationResult();

        assertTrue(_winner.isZero(), "winner should be zero node");
        assertFalse(_finished, "tournament shouldn't be finished");
        assertTrue(
            _finalState.eq(Machine.ZERO_STATE), "final state should be zero"
        );

        // player 0 should win after fast forward time to tournament finishes
        uint256 _t = vm.getBlockNumber();
        uint256 _tournamentFinish = _t + Time.Duration.unwrap(MAX_ALLOWANCE);

        vm.roll(_tournamentFinish);
        (_finished, _winner, _finalState) = topTournament.arbitrationResult();

        uint256 _winnerPlayer = 0;
        assertTrue(
            _winner.eq(
                playerNodes[_winnerPlayer][HistoricalGeometry.height(0)]
            ),
            "winner should be player 0"
        );
        assertTrue(_finished, "tournament should be finished");
        assertTrue(
            _finalState.eq(Util.finalStates[_winnerPlayer]),
            "final state should match"
        );

        // rewind time in half and pair commitment, expect a match
        vm.roll(_t);
        // player 1 joins tournament
        uint256 _opponent = 1;
        Util.joinTournament(topTournament, _opponent);

        // no dangling commitment available, should revert
        vm.roll(_tournamentFinish);
        (_finished, _winner, _finalState) = topTournament.arbitrationResult();

        // tournament not finished when still match going on
        assertTrue(_winner.isZero(), "winner should be zero node");
        assertFalse(_finished, "tournament shouldn't be finished");
        assertTrue(
            _finalState.eq(Machine.ZERO_STATE), "final state should be zero"
        );
    }

    function testTryRecoveringRootBondIsIdempotent() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));

        uint256 winnerBalanceBefore = addrs[0].balance;
        uint256 tournamentBalanceBefore = address(topTournament).balance;

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(
            addrs[0].balance, winnerBalanceBefore + tournamentBalanceBefore
        );
        assertEq(address(topTournament).balance, 0);

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(
            addrs[0].balance, winnerBalanceBefore + tournamentBalanceBefore
        );
        assertEq(address(topTournament).balance, 0);
    }

    function testFuzzTryRecoveringRootBondCapsPayoutAndBurnsResidual(uint256 remainingBalance)
        public
    {
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));

        uint256 bond = topTournament.bondValue();
        remainingBalance = bound(remainingBalance, 0, 3 * bond);
        vm.deal(address(topTournament), remainingBalance);

        uint256 winnerBalanceBefore = addrs[0].balance;
        uint256 burnedBalanceBefore = address(0).balance;
        uint256 expectedWinnerPayment = remainingBalance <= bond
            ? remainingBalance
            : bond + (remainingBalance - bond) / 10;

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(
            addrs[0].balance,
            winnerBalanceBefore + expectedWinnerPayment,
            "winner payment should be one bond plus a tenth of the residual"
        );
        assertEq(
            address(0).balance,
            burnedBalanceBefore + remainingBalance - expectedWinnerPayment,
            "residual balance should be burned"
        );
        assertEq(address(topTournament).balance, 0);

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(addrs[0].balance, winnerBalanceBefore + expectedWinnerPayment);
        assertEq(
            address(0).balance,
            burnedBalanceBefore + remainingBalance - expectedWinnerPayment
        );
    }

    function testTryRecoveringRootBondPreservesBalanceForRetry() public {
        ConfigurableBondReceiver receiver = new ConfigurableBondReceiver();
        topTournament = _initializeReceiverTournament(address(receiver));
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));

        uint256 bond = topTournament.bondValue();
        uint256 remainingBalance = 3 * bond;
        vm.deal(address(topTournament), remainingBalance);

        uint256 receiverBalanceBefore = address(receiver).balance;
        uint256 burnedBalanceBefore = address(0).balance;

        assertFalse(topTournament.tryRecoveringBond());
        assertEq(address(receiver).balance, receiverBalanceBefore);
        assertEq(address(0).balance, burnedBalanceBefore);
        assertEq(address(topTournament).balance, remainingBalance);

        receiver.acceptPayments();
        uint256 payment = bond + (remainingBalance - bond) / 10;
        assertTrue(topTournament.tryRecoveringBond());
        assertEq(address(receiver).balance, receiverBalanceBefore + payment);
        assertEq(
            address(0).balance, burnedBalanceBefore + remainingBalance - payment
        );
        assertEq(address(topTournament).balance, 0);

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(address(receiver).balance, receiverBalanceBefore + payment);
        assertEq(
            address(0).balance, burnedBalanceBefore + remainingBalance - payment
        );
    }

    function testTryRecoveringEmptyRootBondSkipsRecipientCall() public {
        ConfigurableBondReceiver receiver = new ConfigurableBondReceiver();
        topTournament = _initializeReceiverTournament(address(receiver));
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));
        vm.deal(address(topTournament), 0);

        assertTrue(topTournament.tryRecoveringBond());
        assertEq(address(receiver).balance, 0);
        assertEq(address(topTournament).balance, 0);

        assertTrue(topTournament.tryRecoveringBond());
    }

    function _initializeReceiverTournament(address receiver)
        private
        returns (ITournament tournament)
    {
        tournament = FACTORY.instantiate(ONE_STATE, IDataProvider(address(0)));
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        uint256 bond = tournament.bondValue();

        vm.deal(receiver, bond);
        vm.prank(receiver);
        tournament.joinTournament{value: bond}(
            ONE_STATE,
            generateFinalStateProof(0, height),
            playerNodes[0][height - 1],
            playerNodes[0][height - 1]
        );
    }

    function testInner() public {
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

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 2 joins tournament
        _opponent = 2;
        _height = 0;
        Util.joinTournament(topTournament, _opponent);

        _matchId = Util.historicalMatchId(_opponent, _height);
        _match = topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        _playerToSeal = Util.advanceMatch(topTournament, _matchId, _opponent);

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        uint256 step = 1 << HistoricalGeometry.log2step(0);
        uint256 _leafPosition = (1 << HistoricalGeometry.height(0)) - 1;

        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            step * _leafPosition,
            "agree cycle should be the second right most leaf"
        );
    }
}
