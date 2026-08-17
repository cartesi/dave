// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {InspectableTournament} from "./InspectableTournament.sol";
import {ProofSelectedStateTransition} from "./ProofSelectedStateTransition.sol";

library SmallSingleLevelGeometry {
    uint64 internal constant LEVELS = 1;
    uint64 internal constant HEIGHT = 3;
    uint64 internal constant LOG2_STEP = 0;
}

contract SmallSingleLevelParametersProvider is ITournamentParametersProvider {
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
        if (level != 0) revert InvalidLevel(level);
        return TournamentParameters({
            levels: SmallSingleLevelGeometry.LEVELS,
            log2step: SmallSingleLevelGeometry.LOG2_STEP,
            height: SmallSingleLevelGeometry.HEIGHT,
            responseBudget: RESPONSE_BUDGET,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}

contract SmallSingleLevelTournamentFactory is MultiLevelTournamentFactory {
    constructor(Time.Duration responseBudget, Time.Duration maxAllowance)
        MultiLevelTournamentFactory(
            new InspectableTournament(),
            new SmallSingleLevelParametersProvider(
                responseBudget, maxAllowance
            ),
            new ProofSelectedStateTransition()
        )
    {}
}
