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

contract MiddleTournamentTest is Util, Test {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable factory;
    TopTournament topTournament;
    MiddleTournament middleTournament;

    event newInnerTournament(Match.IdHash indexed, NonRootTournament);

    constructor() {
        factory = Util.instantiateTournamentFactory();
    }

    function setUp() public {}

    function testInnerWinner() public {
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

        (bool _finished, Tree.Node _winner,) =
            middleTournament.innerTournamentWinner();
        assertFalse(_finished, "winner should be zero node");

        // player 0 should win after fast forward time to inner tournament finishes
        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _rootTournamentFinish = _t
            + Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE)
            + Time.Duration.unwrap(ArbitrationConstants.MATCH_EFFORT);
        Util.joinTournament(middleTournament, 0);

        vm.roll(_rootTournamentFinish);
        (_finished, _winner,) = middleTournament.innerTournamentWinner();
        topTournament.winInnerMatch(
            middleTournament,
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 1]
        );

        {
            (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState)
            = topTournament.arbitrationResult();

            uint256 _winnerPlayer = 0;
            assertTrue(
                _commitment.eq(
                    playerNodes[_winnerPlayer][ArbitrationConstants.height(0)]
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
        topTournament = Util.initializePlayer0Tournament(factory);

        // pair commitment, expect a match
        // player 1 joins tournament
        _height = 0;
        Util.joinTournament(topTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
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

        (_finished, _winner,) = middleTournament.innerTournamentWinner();
        assertTrue(_winner.isZero(), "winner should be zero node");

        _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        _rootTournamentFinish =
            _t + Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE);
        uint256 _middleTournamentFinish = _rootTournamentFinish
            + Time.Duration.unwrap(ArbitrationConstants.MATCH_EFFORT);

        Util.joinTournament(middleTournament, 0);

        //let player 1 join, then timeout player 0
        Util.joinTournament(middleTournament, _opponent);

        (Clock.State memory _player0Clock,) = middleTournament.getCommitment(
            playerNodes[0][ArbitrationConstants.height(_height)]
        );
        _matchId = Util.matchId(_opponent, _height);
        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        vm.expectRevert(Tournament.WinByTimeout.selector);
        middleTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][ArbitrationConstants.height(1) - 1],
            playerNodes[1][ArbitrationConstants.height(1) - 1]
        );

        vm.roll(
            Time.Instant.unwrap(
                _player0Clock.startInstant.add(_player0Clock.allowance)
            )
        );
        middleTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][ArbitrationConstants.height(1) - 1],
            playerNodes[1][ArbitrationConstants.height(1) - 1]
        );

        _match = middleTournament.getMatch(_matchId.hashFromId());
        assertFalse(_match.exists(), "match should be deleted");

        vm.roll(_middleTournamentFinish);
        (_finished, _winner,) = middleTournament.innerTournamentWinner();
        topTournament.winInnerMatch(
            middleTournament,
            playerNodes[1][ArbitrationConstants.height(0) - 1],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
        );

        {
            vm.roll(_rootTournamentFinish);
            (bool _finishedTop, Tree.Node _commitment, Machine.Hash _finalState)
            = topTournament.arbitrationResult();

            uint256 _winnerPlayer = 1;
            assertTrue(
                _commitment.eq(
                    playerNodes[_winnerPlayer][ArbitrationConstants.height(0)]
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
}
