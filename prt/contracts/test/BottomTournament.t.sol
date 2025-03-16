// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/Test.sol";

import "./Util.sol";
import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/arbitration-config/CanonicalConstants.sol";

pragma solidity ^0.8.0;

contract BottomTournamentTest is Util, Test {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable factory;
    CartesiStateTransition immutable stateTransition;
    TopTournament topTournament;
    MiddleTournament middleTournament;
    BottomTournament bottomTournament;

    error WrongNodesForStep();

    event newInnerTournament(Match.IdHash indexed, NonRootTournament);

    constructor() {
        (factory, stateTransition) = Util.instantiateTournamentFactory();
    }

    function setUp() public {}

    function testCommitmentOneWon() public {
        topTournament = Util.initializePlayer0Tournament(factory);

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
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament = MiddleTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

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
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament = BottomTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

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
            address(stateTransition),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.ONE_STATE))
        );

        Util.winLeafMatch(bottomTournament, _matchId, _playerToSeal);
    }

    function testCommitmentTwoWon() public {
        topTournament = Util.initializePlayer0Tournament(factory);

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

        uint256 cycle = (
            1
                << (
                    ArbitrationConstants.height(0)
                        + ArbitrationConstants.log2step(0)
                )
        ) - (1 << ArbitrationConstants.log2step(0));
        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141503507410452480"
        );

        Vm.Log[] memory _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament = MiddleTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

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

        cycle = (
            1
                << (
                    ArbitrationConstants.height(0)
                        + ArbitrationConstants.log2step(0)
                )
        ) - (1 << ArbitrationConstants.log2step(1));
        assertEq(
            middleTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141521099462279168"
        );

        _entries = vm.getRecordedLogs();
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament = BottomTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

        Util.joinTournament(bottomTournament, 0);
        Util.joinTournament(bottomTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        _playerToSeal = Util.advanceMatch(bottomTournament, _matchId, _opponent);

        // seal match
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        cycle = (
            1
                << (
                    ArbitrationConstants.height(0)
                        + ArbitrationConstants.log2step(0)
                )
        ) - (1 << ArbitrationConstants.log2step(2));
        assertEq(
            bottomTournament.getMatchCycle(_matchId.hashFromId()),
            cycle,
            "agree cycle should be 4951760157141521099596496895"
        );

        vm.mockCall(
            address(stateTransition),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.TWO_STATE))
        );
        Util.winLeafMatch(bottomTournament, _matchId, 2);
    }

    function testWrongNode() public {
        topTournament = Util.initializePlayer0Tournament(factory);

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
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        middleTournament = MiddleTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

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
        assertEq(_entries[0].topics.length, 2);
        assertEq(
            _entries[0].topics[0],
            keccak256("newInnerTournament(bytes32,address)")
        );
        assertEq(
            _entries[0].topics[1], Match.IdHash.unwrap(_matchId.hashFromId())
        );

        bottomTournament = BottomTournament(
            address(bytes20(bytes32(_entries[0].data) << (12 * 8)))
        );

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
            address(stateTransition),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(Util.ONE_STATE))
        );
        vm.expectRevert(WrongNodesForStep.selector);
        bottomTournament.winLeafMatch(
            _matchId, Util.ONE_NODE, Util.ONE_NODE, new bytes(0)
        );
    }
}
