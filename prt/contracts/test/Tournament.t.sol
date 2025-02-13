// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/console.sol";
import "forge-std/Test.sol";

import "./Util.sol";
import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/CanonicalConstants.sol";

pragma solidity ^0.8.0;

contract TournamentTest is Util, Test {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable factory;
    TopTournament topTournament;
    MiddleTournament middleTournament;

    event matchCreated(
        Tree.Node indexed one, Tree.Node indexed two, Tree.Node leftOfTwo
    );

    constructor() {
        factory = Util.instantiateTournamentFactory();
    }

    function setUp() public {}

    function testJoinTournament() public {
        topTournament = Util.initializePlayer0Tournament(factory);

        // pair commitment, expect a match
        vm.expectEmit(true, true, false, true, address(topTournament));
        emit matchCreated(
            playerNodes[0][ArbitrationConstants.height(0)],
            playerNodes[1][ArbitrationConstants.height(0)],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
        );
        // player 1 joins tournament
        uint256 _opponent = 1;
        Util.joinTournament(topTournament, _opponent);
    }

    // function testDuplicateJoinTournament() public {
    //     topTournament = Util.initializePlayer0Tournament(factory);

    //     // duplicate commitment should be reverted
    //     vm.expectRevert("clock is initialized");
    //     Util.joinTournament(topTournament, 0);
    // }

    function testTimeout() public {
        topTournament = Util.initializePlayer0Tournament(factory);

        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _tournamentFinishWithMatch = _t
            + Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE)
            + Time.Duration.unwrap(ArbitrationConstants.MATCH_EFFORT);

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
            Time.Instant.unwrap(
                _player0Clock.startInstant.add(_player0Clock.allowance)
            )
        );
        assertTrue(
            topTournament.canWinMatchByTimeout(_matchId),
            "should be able to win match by timeout"
        );
        topTournament.winMatchByTimeout(
            _matchId,
            playerNodes[1][ArbitrationConstants.height(0) - 1],
            playerNodes[1][ArbitrationConstants.height(0) - 1]
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

        topTournament = Util.initializePlayer0Tournament(factory);
        _t = vm.getBlockNumber();

        // the delay is increased when a match is created
        _tournamentFinishWithMatch = _t
            + Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE)
            + Time.Duration.unwrap(ArbitrationConstants.MATCH_EFFORT);

        // player 1 joins tournament
        Util.joinTournament(topTournament, _opponent);

        // player 0 should win after fast forward time to player 1 timeout
        // player 1 timeout first because he's supposed to advance match after player 0 advanced
        _matchId = Util.matchId(_opponent, _height);

        topTournament.advanceMatch(
            _matchId,
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 1],
            playerNodes[0][ArbitrationConstants.height(0) - 2],
            playerNodes[0][ArbitrationConstants.height(0) - 2]
        );
        (Clock.State memory _player1Clock,) = topTournament.getCommitment(
            playerNodes[1][ArbitrationConstants.height(0)]
        );
        vm.roll(
            Time.Instant.unwrap(
                _player1Clock.startInstant.add(_player1Clock.allowance)
            )
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

        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _rootTournamentFinish =
            _t + 2 * Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE);

        vm.roll(_rootTournamentFinish - 1);
        // cannot eliminate match when both blocks still have time
        vm.expectRevert(Tournament.EliminateByTimeout.selector);
        topTournament.eliminateMatchByTimeout(_matchId);

        vm.roll(_rootTournamentFinish);
        topTournament.eliminateMatchByTimeout(_matchId);
    }
}
