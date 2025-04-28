// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std-1.9.6/src/Test.sol";

import "./Util.sol";
import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/arbitration-config/CanonicalConstants.sol";

pragma solidity ^0.8.0;

contract TopTournamentTest is Util, Test {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable factory;
    TopTournament topTournament;

    constructor() {
        (factory,) = Util.instantiateTournamentFactory();
    }

    function setUp() public {}

    function testRootWinner() public {
        topTournament = Util.initializePlayer0Tournament(factory);

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
        uint256 _tournamentFinish =
            _t + Time.Duration.unwrap(ArbitrationConstants.MAX_ALLOWANCE);

        vm.roll(_tournamentFinish);
        (_finished, _winner, _finalState) = topTournament.arbitrationResult();

        uint256 _winnerPlayer = 0;
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

    function testInner() public {
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

        topTournament = Util.initializePlayer0Tournament(factory);

        // pair commitment, expect a match
        // player 2 joins tournament
        _opponent = 2;
        _height = 0;
        Util.joinTournament(topTournament, _opponent);

        _matchId = Util.matchId(_opponent, _height);
        _match = topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        // advance match to end, this match will always advance to right tree
        _playerToSeal = Util.advanceMatch(topTournament, _matchId, _opponent);

        // seal match
        Util.sealInnerMatchAndCreateInnerTournament(
            topTournament, _matchId, _playerToSeal
        );
        _height += 1;

        uint256 step = 1 << ArbitrationConstants.log2step(0);
        uint256 leaf_position = (1 << ArbitrationConstants.height(0)) - 1;

        assertEq(
            topTournament.getMatchCycle(_matchId.hashFromId()),
            step * leaf_position,
            "agree cycle should be the second right most leaf"
        );
    }
}
