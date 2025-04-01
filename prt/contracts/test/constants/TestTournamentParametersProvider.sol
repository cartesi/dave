// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import "prt-contracts/../test/constants/TestConstants.sol";

contract TestTournamentParametersProvider is ITournamentParametersProvider {
    /// @inheritdoc ITournamentParametersProvider
    function tournamentParameters(uint64 level)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: TestArbitrationConstants.LEVELS,
            log2step: TestArbitrationConstants.log2step(level),
            height: TestArbitrationConstants.height(level),
            matchEffort: TestArbitrationConstants.MATCH_EFFORT,
            maxAllowance: TestArbitrationConstants.MAX_ALLOWANCE
        });
    }
}
