// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "./InspectableTournament.sol";
import {ProofSelectedStateTransition} from "./ProofSelectedStateTransition.sol";
import {SmallFullTree} from "./SmallFullTree.sol";

/// @dev Four height-one rows in which each parent leaf spans one complete
/// child tree. This miniature is a recursion witness, not a deployable profile.
library SmallFourLevelGeometry {
    uint64 internal constant LEVELS = 4;
    uint64 internal constant HEIGHT = 1;

    error InvalidLevel(uint64 level);

    function log2step(uint64 level) internal pure returns (uint64) {
        if (level == 0) return 3;
        if (level == 1) return 2;
        if (level == 2) return 1;
        if (level == 3) return 0;
        revert InvalidLevel(level);
    }
}

/// @dev Coordinate-coherent commitments sampled from two fine state tables.
/// The tables agree through cycle 15 and disagree at cycle 16. They exercise
/// recursive commitment plumbing; they do not model machine execution.
library SmallFourLevelClaims {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint8 internal constant CLAIM_ONE = 0;
    uint8 internal constant CLAIM_TWO = 1;
    uint256 internal constant FINAL_CYCLE = 16;

    error InvalidClaim(uint8 claim);
    error InvalidCycle(uint256 cycle);

    function initialState() internal pure returns (Machine.Hash) {
        return Machine.Hash.wrap(bytes32(uint256(0x4000)));
    }

    function stateAfter(uint8 claim, uint256 cycle)
        internal
        pure
        returns (Machine.Hash)
    {
        if (claim > CLAIM_TWO) revert InvalidClaim(claim);
        if (cycle > FINAL_CYCLE) revert InvalidCycle(cycle);
        if (cycle == 0) return initialState();

        uint256 value = 0x4100 + cycle;
        if (claim == CLAIM_TWO && cycle == FINAL_CYCLE) {
            value = 0x4200 + cycle;
        }
        return Machine.Hash.wrap(bytes32(value));
    }

    function startCycle(uint64 level) internal pure returns (uint256) {
        SmallFourLevelGeometry.log2step(level);
        return
            FINAL_CYCLE
                - (uint256(1) << (SmallFourLevelGeometry.LEVELS - level));
    }

    function tree(uint8 claim, uint64 level)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        uint256 start = startCycle(level);
        uint256 step = uint256(1) << SmallFourLevelGeometry.log2step(level);
        Tree.Node[] memory leaves = new Tree.Node[](2);
        leaves[0] = Tree.Node
            .wrap(Machine.Hash.unwrap(stateAfter(claim, start + step)));
        leaves[1] = Tree.Node
            .wrap(Machine.Hash.unwrap(stateAfter(claim, start + 2 * step)));
        return SmallFullTree.buildFromLeaves(leaves);
    }
}

contract SmallFourLevelParametersProvider is ITournamentParametersProvider {
    Time.Duration internal immutable MATCH_EFFORT;
    Time.Duration internal immutable MAX_ALLOWANCE;

    constructor(Time.Duration matchEffort, Time.Duration maxAllowance) {
        MATCH_EFFORT = matchEffort;
        MAX_ALLOWANCE = maxAllowance;
    }

    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: SmallFourLevelGeometry.LEVELS,
            log2step: SmallFourLevelGeometry.log2step(level),
            height: SmallFourLevelGeometry.HEIGHT,
            matchEffort: MATCH_EFFORT,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}

contract SmallFourLevelTournamentFactory is MultiLevelTournamentFactory {
    constructor(Time.Duration matchEffort, Time.Duration maxAllowance)
        MultiLevelTournamentFactory(
            new InspectableTournament(),
            new SmallFourLevelParametersProvider(matchEffort, maxAllowance),
            new ProofSelectedStateTransition()
        )
    {}
}
