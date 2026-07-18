// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

/// @dev Frozen test profile for the historical top/middle/bottom scenarios.
library HistoricalThreeLevelGeometry {
    uint64 internal constant LEVELS = 3;

    function log2step(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory values = [uint64(44), uint64(27), uint64(0)];
        return values[level];
    }

    function height(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory values = [uint64(48), uint64(17), uint64(27)];
        return values[level];
    }
}

contract HistoricalThreeLevelParametersProvider is
    ITournamentParametersProvider
{
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
            levels: HistoricalThreeLevelGeometry.LEVELS,
            log2step: HistoricalThreeLevelGeometry.log2step(level),
            height: HistoricalThreeLevelGeometry.height(level),
            matchEffort: MATCH_EFFORT,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}
