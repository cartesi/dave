// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Time} from "prt-contracts/tournament/libs/Time.sol";

/// @param levels Number of tournament levels in the table
/// @param log2step Base-2 stride between adjacent commitment leaves
/// @param height Commitment-tree height
/// @param responseBudget Time granted for one action to land (inclusion);
/// each response is discounted by it
/// @param commitmentBudget Time granted to build one inner tournament's
/// commitment; the same for every level (see ClockBudgets)
/// @param maxAllowance Root allowance
struct TournamentParameters {
    uint64 levels;
    uint64 log2step;
    uint64 height;
    Time.Duration responseBudget;
    Time.Duration commitmentBudget;
    Time.Duration maxAllowance;
}
