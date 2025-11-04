// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ArbitrationConstants} from "./ArbitrationConstants.sol";
import {
    ITournamentParametersProvider
} from "./ITournamentParametersProvider.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";

contract CanonicalTournamentParametersProvider is
    ITournamentParametersProvider
{
    Time.Duration immutable MATCH_EFFORT;
    Time.Duration immutable MAX_ALLOWANCE;

    constructor(Time.Duration matchEffort, Time.Duration maxAllowance) {
        MATCH_EFFORT = matchEffort;
        MAX_ALLOWANCE = maxAllowance;
    }

    /// @inheritdoc ITournamentParametersProvider
    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: ArbitrationConstants.LEVELS,
            log2step: ArbitrationConstants.log2step(level),
            height: ArbitrationConstants.height(level),
            matchEffort: MATCH_EFFORT,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}
