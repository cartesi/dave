// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./ITournamentParametersProvider.sol";
import "./CanonicalConstants.sol";

contract CanonicalTournamentParametersProvider is
    ITournamentParametersProvider
{
    Time.Duration immutable _matchEffort;
    Time.Duration immutable _maxAllowance;

    constructor(Time.Duration matchEffort, Time.Duration maxAllowance) {
        _matchEffort = matchEffort;
        _maxAllowance = maxAllowance;
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
            matchEffort: _matchEffort,
            maxAllowance: _maxAllowance
        });
    }
}
