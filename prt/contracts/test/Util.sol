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

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {
    ArbitrationConstants
} from "src/arbitration-config/ArbitrationConstants.sol";
import {
    CanonicalTournamentParametersProvider
} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";
import {
    CmioStateTransition
} from "src/state-transition/CmioStateTransition.sol";
import {
    RiscVStateTransition
} from "src/state-transition/RiscVStateTransition.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

// Simple parameters provider for single-level tournaments (levels = 1)
contract SingleLevelTournamentParametersProvider is
    ITournamentParametersProvider
{
    Time.Duration immutable MATCH_EFFORT;
    Time.Duration immutable MAX_ALLOWANCE;
    uint64 immutable LOG2_STEP;
    uint64 immutable HEIGHT;

    constructor(
        uint64 log2step,
        uint64 height,
        Time.Duration matchEffort,
        Time.Duration maxAllowance
    ) {
        LOG2_STEP = log2step;
        HEIGHT = height;
        MATCH_EFFORT = matchEffort;
        MAX_ALLOWANCE = maxAllowance;
    }

    function tournamentParameters(uint64)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: 1, // Single-level tournament
            log2step: LOG2_STEP,
            height: HEIGHT,
            matchEffort: MATCH_EFFORT,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}

contract Util is Test {
    using Tree for Tree.Node;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.State;

    Tree.Node constant ONE_NODE = Tree.Node.wrap(bytes32(uint256(1)));
    Tree.Node constant TWO_NODE = Tree.Node.wrap(bytes32(uint256(2)));
    Machine.Hash constant ONE_STATE = Machine.Hash.wrap(bytes32(uint256(1)));
    Machine.Hash constant TWO_STATE = Machine.Hash.wrap(bytes32(uint256(2)));
    uint64 public constant LOG2_MAX_HEIGHT = 67;

    Time.Duration constant COMMITMENT_EFFORT = Time.Duration.wrap(5 * 60);
    Time.Duration constant CENSORSHIP_TOLERANCE =
        Time.Duration.wrap(5 * 60 * 8);
    Time.Duration constant MATCH_EFFORT = Time.Duration.wrap(5 * 5 * 92);
    Time.Duration constant MAX_ALLOWANCE = Time.Duration
        .wrap(
            Time.Duration.unwrap(CENSORSHIP_TOLERANCE)
                + Time.Duration.unwrap(COMMITMENT_EFFORT)
        );

    // players' commitment node at different height
    // player 0, player 1, and player 2
    Tree.Node[][3] playerNodes;
    Machine.Hash[3] finalStates;
    address[] addrs = [vm.addr(1), vm.addr(2), vm.addr(3)];

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

        vm.deal(address(this), 1000 ether);
        vm.deal(addrs[0], 1000 ether);
        vm.deal(addrs[1], 1000 ether);
        vm.deal(addrs[2], 1000 ether);
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
        ITournament _tournament,
        Match.Id memory _matchId,
        uint256 _opponent
    ) internal returns (uint256 _playerToSeal) {
        (,,, uint64 _current) = _tournament.tournamentLevelConstants();
        for (_current; _current > 1; _current -= 1) {
            uint256 matchAdvancedCountBefore =
                _tournament.getMatchAdvancedCount();
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
            assertEq(
                _tournament.getMatchAdvancedCount(),
                matchAdvancedCountBefore + 1,
                "MatchAdvanced count should be increased by 1"
            );
        }
    }

    // create new _topTournament and player 0 joins it
    function initializePlayer0Tournament(MultiLevelTournamentFactory _factory)
        internal
        returns (ITournament _topTournament)
    {
        _topTournament =
            _factory.instantiate(ONE_STATE, IDataProvider(address(0)));
        // player 0 joins tournament
        joinTournament(_topTournament, 0);
    }

    // create new _topTournament and player 0 joins it
    function initializePlayer0RollupsTournament(MultiLevelTournamentFactory _factory)
        internal
        returns (ITournament _topTournament)
    {
        _topTournament = _factory.instantiate(
            ONE_STATE, IDataProvider(address(0x12345678901234567890))
        );
        // player 0 joins tournament
        joinTournament(_topTournament, 0);
    }

    // _player joins _tournament at _level
    function joinTournament(ITournament _tournament, uint256 _player) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1
            ? playerNodes[1][height - 1]
            : playerNodes[0][height - 1];
        Tree.Node _right = playerNodes[_player][height - 1];
        Machine.Hash _finalState = _player == 0 ? ONE_STATE : TWO_STATE;
        uint256 bondAmount = _tournament.bondValue();
        uint256 commitmentJoinedCountBefore =
            _tournament.getCommitmentJoinedCount();
        uint256 matchCreatedCountBefore = _tournament.getMatchCreatedCount();
        vm.prank(addrs[_player]);
        _tournament.joinTournament{value: bondAmount}(
            _finalState, generateFinalStateProof(_player, height), _left, _right
        );
        assertEq(
            _tournament.getCommitmentJoinedCount(),
            commitmentJoinedCountBefore + 1
        );
        assertGe(
            _tournament.getMatchCreatedCount(),
            matchCreatedCountBefore,
            "MatchCreated count must be non-decreasing"
        );
    }

    function sealLeafMatch(
        ITournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node _right = playerNodes[_player][0];

        _tournament.sealLeafMatch(
            _matchId,
            _left,
            _right,
            ONE_STATE,
            generateDivergenceProof(_player, height)
        );
    }

    function winLeafMatch(
        ITournament _tournament,
        Match.Id memory _matchId,
        uint256 _player
    ) internal {
        (,,, uint64 height) = _tournament.tournamentLevelConstants();
        Tree.Node _left = _player == 1
            ? playerNodes[1][height - 1]
            : playerNodes[0][height - 1];
        Tree.Node _right = playerNodes[_player][height - 1];

        uint256 matchDeletedCountBefore = _tournament.getMatchDeletedCount();
        _tournament.winLeafMatch(_matchId, _left, _right, new bytes(0));
        assertEq(
            _tournament.getMatchDeletedCount(),
            matchDeletedCountBefore + 1,
            "MatchDeleted count should be increased by 1"
        );
    }

    function sealInnerMatchAndCreateInnerTournament(
        ITournament _tournament,
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

    function winMatchByTimeout(
        ITournament _tournament,
        Match.Id memory _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) internal {
        uint256 matchDeletedCountBefore = _tournament.getMatchDeletedCount();
        _tournament.winMatchByTimeout(_matchId, _leftNode, _rightNode);
        assertEq(
            _tournament.getMatchDeletedCount(),
            matchDeletedCountBefore + 1,
            "MatchDeleted count should be increased by 1"
        );
    }

    function eliminateMatchByTimeout(
        ITournament _tournament,
        Match.Id memory _matchId
    ) internal {
        uint256 matchDeletedCountBefore = _tournament.getMatchDeletedCount();
        _tournament.eliminateMatchByTimeout(_matchId);
        assertEq(
            _tournament.getMatchDeletedCount(),
            matchDeletedCountBefore + 1,
            "MatchDeleted count should be increased by 1"
        );
    }

    function winInnerTournament(
        ITournament _tournament,
        ITournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) internal {
        uint256 matchDeletedCountBefore = _tournament.getMatchDeletedCount();
        _tournament.winInnerTournament(_childTournament, _leftNode, _rightNode);
        assertEq(
            _tournament.getMatchDeletedCount(),
            matchDeletedCountBefore + 1,
            "MatchDeleted count should be increased by 1"
        );
    }

    function eliminateInnerTournament(
        ITournament _tournament,
        ITournament _childTournament
    ) internal {
        uint256 matchDeletedCountBefore = _tournament.getMatchDeletedCount();
        _tournament.eliminateInnerTournament(_childTournament);
        assertEq(
            _tournament.getMatchDeletedCount(),
            matchDeletedCountBefore + 1,
            "MatchDeleted count should be increased by 1"
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
        returns (MultiLevelTournamentFactory)
    {
        (CartesiStateTransition stateTransition,,) =
            instantiateStateTransition();
        MultiLevelTournamentFactory singleLevelFactory = new MultiLevelTournamentFactory(
            new Tournament(),
            new SingleLevelTournamentParametersProvider(
                ArbitrationConstants.log2step(0),
                ArbitrationConstants.height(0),
                MATCH_EFFORT,
                MAX_ALLOWANCE
            ),
            stateTransition
        );

        return singleLevelFactory;
    }

    // instantiates all sub-factories and TournamentFactory
    function instantiateTournamentFactory()
        internal
        returns (MultiLevelTournamentFactory, CartesiStateTransition)
    {
        (CartesiStateTransition stateTransition,,) =
            instantiateStateTransition();
        return (
            new MultiLevelTournamentFactory(
                new Tournament(),
                new CanonicalTournamentParametersProvider(
                    MATCH_EFFORT, MAX_ALLOWANCE
                ),
                stateTransition
            ),
            stateTransition
        );
    }

    // instantiates StateTransition
    function instantiateStateTransition()
        internal
        returns (
            CartesiStateTransition,
            RiscVStateTransition,
            CmioStateTransition
        )
    {
        RiscVStateTransition riscVStateTransition = new RiscVStateTransition();
        CmioStateTransition cmioStateTransition = new CmioStateTransition();
        CartesiStateTransition stateTransition = new CartesiStateTransition(
            riscVStateTransition, cmioStateTransition
        );

        return (stateTransition, riscVStateTransition, cmioStateTransition);
    }

    function assertEventCountersEqualZero(ITournament tournament)
        internal
        view
    {
        assertEq(tournament.getCommitmentJoinedCount(), 0);
    }
}
