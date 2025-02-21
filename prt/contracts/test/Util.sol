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

import "src/tournament/libs/Match.sol";
import "src/CanonicalConstants.sol";
import "src/CanonicalTournamentParametersProvider.sol";
import "src/tournament/concretes/TopTournament.sol";
import "src/tournament/concretes/MiddleTournament.sol";

import "src/tournament/factories/SingleLevelTournamentFactory.sol";
import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/tournament/factories/multilevel/TopTournamentFactory.sol";
import "src/tournament/factories/multilevel/MiddleTournamentFactory.sol";
import "src/tournament/factories/multilevel/BottomTournamentFactory.sol";

pragma solidity ^0.8.0;

contract Util {
    using Tree for Tree.Node;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.State;

    Tree.Node constant ONE_NODE = Tree.Node.wrap(bytes32(uint256(1)));
    Tree.Node constant TWO_NODE = Tree.Node.wrap(bytes32(uint256(2)));
    Machine.Hash constant ONE_STATE = Machine.Hash.wrap(bytes32(uint256(1)));
    Machine.Hash constant TWO_STATE = Machine.Hash.wrap(bytes32(uint256(2)));
    uint64 constant LOG2_MAX_HEIGHT = 67;

    // players' commitment node at different height
    // player 0, player 1, and player 2
    Tree.Node[][3] playerNodes;
    Machine.Hash[3] finalStates;

    constructor() {
        playerNodes[0] = new Tree.Node[](LOG2_MAX_HEIGHT + 1);
        playerNodes[1] = new Tree.Node[](LOG2_MAX_HEIGHT + 1);
        playerNodes[2] = new Tree.Node[](LOG2_MAX_HEIGHT + 1);

        playerNodes[0][0] = ONE_NODE;
        playerNodes[1][0] = TWO_NODE;
        playerNodes[2][0] = TWO_NODE;

        finalStates[0] = ONE_STATE;
        finalStates[1] = TWO_STATE;
        finalStates[2] = TWO_STATE;

        for (uint256 _i = 1; _i <= LOG2_MAX_HEIGHT; _i++) {
            // player 0 is all 1
            playerNodes[0][_i] =
                playerNodes[0][_i - 1].join(playerNodes[0][_i - 1]);
            // player 1 is all 2
            playerNodes[1][_i] =
                playerNodes[1][_i - 1].join(playerNodes[1][_i - 1]);
            // player 2 is all 1 but right most leaf node is 2
            playerNodes[2][_i] =
                playerNodes[0][_i - 1].join(playerNodes[2][_i - 1]);
        }
    }

    function generateDivergenceProof(uint256 _player, uint64 _height)
        internal
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory _proof = generateFinalStateProof(_player, _height);
        _proof[0] = Tree.Node.unwrap(playerNodes[_player][0]);

        return _proof;
    }

    function generateFinalStateProof(uint256 _player, uint64 _height)
        internal
        view
        returns (bytes32[] memory)
    {
        // player 0 and player 2 share same proofs
        if (_player == 2) {
            _player = 0;
        }

        bytes32[] memory _proof = new bytes32[](_height);
        for (uint64 _i = 0; _i < _height; _i++) {
            _proof[_i] = Tree.Node.unwrap(playerNodes[_player][_i]);
        }

        return _proof;
    }

    // advance match between player 0 and opponent
    function advanceMatch(
        Tournament _tournament,
        Match.Id memory _matchId,
        uint256 _opponent
    ) internal returns (uint256 _playerToSeal) {
        (,,, uint64 _current) = _tournament.tournamentLevelConstants();
        for (_current; _current > 1; _current -= 1) {
            if (_playerToSeal == 0) {
                // advance match alternately until it can be sealed
                // starts with player 0
                _tournament.advanceMatch(
                    _matchId,
                    playerNodes[0][_current - 1],
                    playerNodes[0][_current - 1],
                    playerNodes[0][_current - 2],
                    playerNodes[0][_current - 2]
                );
                _playerToSeal = _opponent;
            } else {
                if (_playerToSeal == 1) {
                    _tournament.advanceMatch(
                        _matchId,
                        playerNodes[1][_current - 1],
                        playerNodes[1][_current - 1],
                        playerNodes[1][_current - 2],
                        playerNodes[1][_current - 2]
                    );
                } else {
                    _tournament.advanceMatch(
                        _matchId,
                        playerNodes[0][_current - 1],
                        playerNodes[2][_current - 1],
                        playerNodes[0][_current - 2],
                        playerNodes[2][_current - 2]
                    );
                }
                _playerToSeal = 0;
            }
        }
    }

    // create new _topTournament and player 0 joins it
    function initializePlayer0Tournament(MultiLevelTournamentFactory _factory)
        internal
        returns (TopTournament _topTournament)
    {
        _topTournament = TopTournament(
            address(_factory.instantiate(ONE_STATE, IDataProvider(address(0))))
        );
        // player 0 joins tournament
        joinTournament(_topTournament, 0);
    }

    // create new _topTournament and player 0 joins it
    function initializePlayer0RollupsTournament(
        MultiLevelTournamentFactory _factory
    ) internal returns (TopTournament _topTournament) {
        _topTournament = TopTournament(
            address(
                _factory.instantiate(
                    ONE_STATE, IDataProvider(address(0x12345678901234567890))
                )
            )
        );
        // player 0 joins tournament
        joinTournament(_topTournament, 0);
    }

    // _player joins _tournament at _level
    function joinTournament(Tournament _tournament, uint256 _player) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1
            ? playerNodes[1][height - 1]
            : playerNodes[0][height - 1];
        Tree.Node _right = playerNodes[_player][height - 1];
        Machine.Hash _final_state = _player == 0 ? ONE_STATE : TWO_STATE;
        _tournament.joinTournament(
            _final_state,
            generateFinalStateProof(_player, height),
            _left,
            _right
        );
    }

    function sealLeafMatch(
        LeafTournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];
        // Machine.Hash state = _player == 1 ? ONE_STATE : Machine.ZERO_STATE;

        _tournament.sealLeafMatch(
            _matchId,
            _left,
            _right,
            ONE_STATE,
            generateDivergenceProof(_player, height)
        );
    }

    function winLeafMatch(
        LeafTournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];
        // Machine.Hash state = _player == 1 ? ONE_STATE : Machine.ZERO_STATE;

        _tournament.winLeafMatch(_matchId, _left, _right, new bytes(0));
    }

    function winLeafMatchRollupsWithInput(
        LeafTournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];
        // Machine.Hash state = _player == 1 ? ONE_STATE : Machine.ZERO_STATE;

        uint256 length = 20;
        _tournament.winLeafMatch(
            _matchId,
            _left,
            _right,
            abi.encodePacked(abi.encodePacked(length), new bytes(20))
        );
    }

    function winLeafMatchRollupsWithoutInput(
        LeafTournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];
        // Machine.Hash state = _player == 1 ? ONE_STATE : Machine.ZERO_STATE;

        uint256 length = 0;
        _tournament.winLeafMatch(
            _matchId,
            _left,
            _right,
            abi.encodePacked(abi.encodePacked(length), new bytes(0))
        );
    }

    function sealInnerMatchAndCreateInnerTournament(
        NonLeafTournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];

        _tournament.sealInnerMatchAndCreateInnerTournament(
            _matchId,
            _left,
            _right,
            ONE_STATE,
            generateDivergenceProof(_player, height)
        );
    }

    // create match id for player 0 and _opponent at _level
    function matchId(uint256 _opponent, uint64 _level)
        internal
        view
        returns (Match.Id memory)
    {
        return Match.Id(
            playerNodes[0][ArbitrationConstants.height(_level)],
            playerNodes[_opponent][ArbitrationConstants.height(_level)]
        );
    }

    // instantiates all sub-factories and TournamentFactory
    function instantiateSingleLevelTournamentFactory()
        internal
        returns (SingleLevelTournamentFactory)
    {
        SingleLevelTournamentFactory singleLevelFactory = new SingleLevelTournamentFactory(
            ArbitrationConstants.MATCH_EFFORT,
            ArbitrationConstants.MAX_ALLOWANCE,
            ArbitrationConstants.log2step(0),
            ArbitrationConstants.height(0)
        );

        return singleLevelFactory;
    }

    // instantiates all sub-factories and TournamentFactory
    function instantiateTournamentFactory()
        internal
        returns (MultiLevelTournamentFactory)
    {
        return new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            new CanonicalTournamentParametersProvider()
        );
    }
}
