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

import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/tournament/ITournament.sol";
import {
    ArbitrationConstants
} from "src/arbitration-config/ArbitrationConstants.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";

contract BottomTournamentTest is Util {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable FACTORY;
    CartesiStateTransition immutable STATE_TRANSITION;
    ITournament topTournament;
    ITournament middleTournament;
    ITournament bottomTournament;

    error WrongNodesForStep();

    constructor() {
        (FACTORY, STATE_TRANSITION) = Util.instantiateTournamentFactory();
    }

    receive() external payable {}

    function testCommitmentOneWon() public {
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

        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(middleTournament, 0);
        Util.joinTournament(middleTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal = Util.advanceMatch(middleTournament, _matchId, _opponent);

        // expect new inner created (middle 2)
        vm.recordLogs();

        vm.txGasPrice(2);

        uint256 callerBalanceBefore = address(this).balance;
        uint256 tournamentBalanceBefore = address(middleTournament).balance;

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            middleTournament, _matchId, _playerToSeal
        );
        _height += 1;

        uint256 callerBalanceAfter = address(this).balance;
        uint256 tournamentBalanceAfter = address(middleTournament).balance;
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

        assertEq(
            middleTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(bottomTournament, 0);
        Util.joinTournament(bottomTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal = Util.advanceMatch(bottomTournament, _matchId, _opponent);

        callerBalanceBefore = address(this).balance;
        tournamentBalanceBefore = address(bottomTournament).balance;

        // seal match
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        callerBalanceAfter = address(this).balance;
        tournamentBalanceAfter = address(bottomTournament).balance;
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have earned profit to sealLeafMatch"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tounament should have paid gas to sealLeafMatch"
        );

        assertEq(
            bottomTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        vm.mockCall(
            address(STATE_TRANSITION),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.ONE_STATE))
        );

        callerBalanceBefore = address(this).balance;
        tournamentBalanceBefore = address(bottomTournament).balance;

        Util.winLeafMatch(bottomTournament, _matchId, _playerToSeal);

        callerBalanceAfter = address(this).balance;
        tournamentBalanceAfter = address(bottomTournament).balance;
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have earned profit to winLeafMatch"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tounament should have paid gas to winLeafMatch"
        );
    }

    function testBondValue() public {
        testCommitmentOneWon();

        uint256 bondValue = topTournament.bondValue();
        assertGt(bondValue, 0, "Top bond value should be positive");
        assertLt(bondValue, 2 ether, "Top bond value should be reasonable");

        bondValue = middleTournament.bondValue();
        assertGt(bondValue, 0, "Middle bond value should be positive");
        assertLt(bondValue, 2 ether, "Middle bond value should be reasonable");

        bondValue = bottomTournament.bondValue();
        assertGt(bondValue, 0, "Bottom bond value should be positive");
        assertLt(bondValue, 2 ether, "Bottom bond value should be reasonable");
    }

    function testCommitmentTwoWon() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 2 joins tournament
        uint256 _opponent = 2;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.matchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        uint256 _playerToSeal =
            Util.advanceMatch(topTournament, _matchId, _opponent);

        // expect new inner created
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        uint256 cycle =
            (1
                        << (ArbitrationConstants.height(0)
                                + ArbitrationConstants.log2step(0)))
                - (1 << ArbitrationConstants.log2step(0));
        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141503507410452480"
        );

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(middleTournament, 0);
        Util.joinTournament(middleTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        _playerToSeal = Util.advanceMatch(middleTournament, _matchId, _opponent);

        // expect new inner created (middle 2)
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            middleTournament, _matchId, _playerToSeal
        );
        _height += 1;

        cycle =
            (1
                        << (ArbitrationConstants.height(0)
                                + ArbitrationConstants.log2step(0)))
                - (1 << ArbitrationConstants.log2step(1));
        assertEq(
            middleTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141521099462279168"
        );

        _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(bottomTournament, 0);
        Util.joinTournament(bottomTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        _playerToSeal = Util.advanceMatch(bottomTournament, _matchId, _opponent);

        // seal match
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        cycle =
            (1
                        << (ArbitrationConstants.height(0)
                                + ArbitrationConstants.log2step(0)))
                - (1 << ArbitrationConstants.log2step(2));
        assertEq(
            bottomTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141521099596496895"
        );

        vm.mockCall(
            address(STATE_TRANSITION),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.TWO_STATE))
        );
        Util.winLeafMatch(bottomTournament, _matchId, 2);
    }

    function testWrongNode() public {
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

        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(middleTournament, 0);
        Util.joinTournament(middleTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal = Util.advanceMatch(middleTournament, _matchId, _opponent);

        // expect new inner created (middle 2)
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            middleTournament, _matchId, _playerToSeal
        );
        _height += 1;

        assertEq(
            middleTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 3);
        assertEq(
            _entries[0].topics[0],
            keccak256("NewInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(bottomTournament, 0);
        Util.joinTournament(bottomTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal = Util.advanceMatch(bottomTournament, _matchId, _opponent);

        // seal match
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        assertEq(
            bottomTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        vm.mockCall(
            address(STATE_TRANSITION),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.ONE_STATE))
        );
        vm.expectRevert(WrongNodesForStep.selector);
        bottomTournament.winLeafMatch(
            _matchId, Util.ONE_NODE, Util.ONE_NODE, new bytes(0)
        );
    }

    function testPostSealBothClocksRunAndEliminateAfterDoubleTimeout() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // Build down to a ITournament instance via two inner seals
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.matchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        uint256 _playerToSeal =
            Util.advanceMatch(topTournament, _matchId, _opponent);
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        middleTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        Util.joinTournament(middleTournament, 0);
        Util.joinTournament(middleTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "mid match should exist");

        _playerToSeal = Util.advanceMatch(middleTournament, _matchId, _opponent);
        vm.recordLogs();
        Util.sealInnerMatchAndCreateInnerTournament(
            middleTournament, _matchId, _playerToSeal
        );
        _height += 1;

        _entries = vm.getRecordedLogs();
        bottomTournament =
            ITournament(address(uint160(uint256(_entries[0].topics[2]))));

        // Both players join bottom-level tournament and reach leaf
        Util.joinTournament(bottomTournament, 0);
        Util.joinTournament(bottomTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "bottom match should exist");

        _playerToSeal = Util.advanceMatch(bottomTournament, _matchId, _opponent);

        // Seal leaf: both clocks should be running afterwards
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        (Clock.State memory c1,) =
            bottomTournament.getCommitment(_matchId.commitmentOne);
        (Clock.State memory c2,) =
            bottomTournament.getCommitment(_matchId.commitmentTwo);

        assertFalse(c1.startInstant.isZero(), "c1 should be running");
        assertFalse(c2.startInstant.isZero(), "c2 should be running");

        // Elimination should fail immediately after seal (both have time left)
        vm.expectRevert(ITournament.BothClocksHaveNotTimedOut.selector);
        bottomTournament.eliminateMatchByTimeout(_matchId);

        // Fast-forward to when both clocks are exhausted and eliminate
        uint256 end1 = Time.Instant.unwrap(c1.startInstant.add(c1.allowance));
        uint256 end2 = Time.Instant.unwrap(c2.startInstant.add(c2.allowance));
        uint256 endMax = end1 > end2 ? end1 : end2;
        vm.roll(endMax);
        bottomTournament.eliminateMatchByTimeout(_matchId);

        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertFalse(
            _match.exists(), "match should be deleted after elimination"
        );
    }
}
