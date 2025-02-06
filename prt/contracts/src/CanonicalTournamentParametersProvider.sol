// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./ITournamentParametersProvider.sol";
import "./CanonicalConstants.sol";

contract CanonicalTournamentParametersProvider is
    ITournamentParametersProvider
{
    /// @inheritdoc ITournamentParametersProvider
    function tournamentParameters(uint64 level)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: ArbitrationConstants.LEVELS,
            log2step: ArbitrationConstants.log2step(level),
            height: ArbitrationConstants.height(level),
            matchEffort: ArbitrationConstants.MATCH_EFFORT,
            maxAllowance: ArbitrationConstants.MAX_ALLOWANCE
        });
    }
}
