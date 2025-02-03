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
import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/CanonicalConstants.sol";

pragma solidity ^0.8.0;

contract BottomTournamentTest is Util, Test {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable factory;
    TopTournament topTournament;
    MiddleTournament middleTournament;
    BottomTournament bottomTournament;

    event newInnerTournament(Match.IdHash indexed, NonRootTournament);

    constructor() {
        factory = Util.instantiateTournamentFactory();
    }

    function setUp() public {}

    function testBottom() public {
        topTournament = Util.initializePlayer0Tournament(factory);

        // pair commitment, expect a match
        // player 1 joins tournament
        Util.joinTournament(topTournament, 1, 0);

        Match.Id memory _matchId = Util.matchId(1, 0);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        uint256 _playerToSeal =
            Util.advanceMatch01AtLevel(topTournament, _matchId, 0);

        // expect new inner created
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );

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

        Util.joinTournament(middleTournament, 0, 1);
        Util.joinTournament(middleTournament, 1, 1);

        _matchId = Util.matchId(1, 1);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal =
            Util.advanceMatch01AtLevel(middleTournament, _matchId, 1);

        // expect new inner created (middle 2)
        vm.recordLogs();

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            middleTournament, _matchId, _playerToSeal
        );

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

        Util.joinTournament(bottomTournament, 0, 2);
        Util.joinTournament(bottomTournament, 1, 2);

        _matchId = Util.matchId(1, 2);
        _match = bottomTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to left tree
        _playerToSeal =
            Util.advanceMatch01AtLevel(bottomTournament, _matchId, 2);

        // seal match
        Util.sealLeafMatch(bottomTournament, _matchId, _playerToSeal);

        assertEq(
            bottomTournament.getMatchCycle(_matchId.hashFromId()),
            0,
            "agree cycle should be zero"
        );

        vm.expectRevert();
        // win match, expect revert
        Util.winLeafMatch(bottomTournament, _matchId, _playerToSeal);
    }
}
