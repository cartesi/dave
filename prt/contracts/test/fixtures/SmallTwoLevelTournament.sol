// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {InspectableTournament} from "./InspectableTournament.sol";
import {ProofSelectedStateTransition} from "./ProofSelectedStateTransition.sol";

/// @dev Small geometry in which one root leaf spans one complete child tree:
/// `root.log2step == leaf.log2step + leaf.height`.
library SmallTwoLevelGeometry {
    uint64 internal constant LEVELS = 2;
    uint64 internal constant ROOT_HEIGHT = 2;
    uint64 internal constant ROOT_LOG2_STEP = 2;
    uint64 internal constant LEAF_HEIGHT = 2;
    uint64 internal constant LEAF_LOG2_STEP = 0;
}

contract SmallTwoLevelParametersProvider is ITournamentParametersProvider {
    error InvalidLevel(uint64 level);

    Time.Duration internal immutable RESPONSE_BUDGET;
    Time.Duration internal immutable MAX_ALLOWANCE;

    constructor(Time.Duration responseBudget, Time.Duration maxAllowance) {
        RESPONSE_BUDGET = responseBudget;
        MAX_ALLOWANCE = maxAllowance;
    }

    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        if (level == 0) {
            return TournamentParameters({
                levels: SmallTwoLevelGeometry.LEVELS,
                log2step: SmallTwoLevelGeometry.ROOT_LOG2_STEP,
                height: SmallTwoLevelGeometry.ROOT_HEIGHT,
                responseBudget: RESPONSE_BUDGET,
                maxAllowance: MAX_ALLOWANCE
            });
        }
        if (level == 1) {
            return TournamentParameters({
                levels: SmallTwoLevelGeometry.LEVELS,
                log2step: SmallTwoLevelGeometry.LEAF_LOG2_STEP,
                height: SmallTwoLevelGeometry.LEAF_HEIGHT,
                responseBudget: RESPONSE_BUDGET,
                maxAllowance: MAX_ALLOWANCE
            });
        }
        revert InvalidLevel(level);
    }
}

contract SmallTwoLevelTournamentFactory is MultiLevelTournamentFactory {
    constructor(Time.Duration responseBudget, Time.Duration maxAllowance)
        MultiLevelTournamentFactory(
            new InspectableTournament(),
            new SmallTwoLevelParametersProvider(responseBudget, maxAllowance),
            new ProofSelectedStateTransition()
        )
    {}
}
