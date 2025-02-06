// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {TournamentParameters} from "./TournamentParameters.sol";

interface ITournamentParametersProvider {
    /// @notice Get tournament parameters for a given level.
    /// @param level The tournament level (0 = top)
    function tournamentParameters(uint64 level)
        external
        view
        returns (TournamentParameters memory);
}
