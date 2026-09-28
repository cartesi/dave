// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {TournamentParameterTableValidator} from "./TournamentParameterTableValidator.sol";
import {ITournamentParametersProvider} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {TournamentParameters} from "prt-contracts/types/TournamentParameters.sol";

/// @notice Test-only provider serving a table fixed at construction.
/// @dev Production deploys the compile-time canonical table. Devnet geometry
/// profiles deploy this instead, so clients can be exercised against another
/// geometry before the canonical constants change. The constructor runs the
/// generation validator, so a profile cannot deploy an invalid table.
contract TableTournamentParametersProvider is ITournamentParametersProvider {
    error RaggedTable(uint256 log2steps, uint256 heights);
    error UnknownLevel(uint64 level, uint64 levels);

    TournamentParameters[] internal _table;

    constructor(
        uint64[] memory log2steps,
        uint64[] memory heights,
        Time.Duration responseBudget,
        Time.Duration maxAllowance,
        uint64 expectedTotalLog2Span
    ) {
        require(
            log2steps.length == heights.length,
            RaggedTable(log2steps.length, heights.length)
        );
        TournamentParameters[] memory table =
            new TournamentParameters[](log2steps.length);
        for (uint256 i; i < log2steps.length; ++i) {
            table[i] = TournamentParameters({
                levels: uint64(log2steps.length),
                log2step: log2steps[i],
                height: heights[i],
                responseBudget: responseBudget,
                maxAllowance: maxAllowance
            });
        }
        TournamentParameterTableValidator.validate(table, expectedTotalLog2Span);
        for (uint256 i; i < table.length; ++i) {
            _table.push(table[i]);
        }
    }

    /// @inheritdoc ITournamentParametersProvider
    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        if (level >= _table.length) {
            revert UnknownLevel(level, uint64(_table.length));
        }
        return _table[level];
    }
}
