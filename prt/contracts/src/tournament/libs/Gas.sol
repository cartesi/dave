// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

/// @notice Configured gas-unit allocations used to cap action refunds.
/// @dev Reviewed allocations include the fixed unmetered allowance, measured
/// modifier-body cost, and explicit headroom. `WIN_LEAF_MATCH` is a provisional
/// subsidy for a canonical ordinary proof, not a bound across proof classes.
/// No allocation is a whole-transaction or receipt-exact gas bound. Work-price
/// and payment policy live in `Bond`.
library Gas {
    /// @notice Fixed per-action allowance for work outside the gas snapshots.
    /// @dev This is policy, not measured transaction-intrinsic gas. A batch
    /// receives it once for every successful refundable action.
    uint256 constant TX = 25000;

    uint256 constant ADVANCE_MATCH = 100000 + TX;
    uint256 constant WIN_MATCH_BY_TIMEOUT = 235000 + TX;
    uint256 constant ELIMINATE_MATCH_BY_TIMEOUT = 110000 + TX;
    uint256 constant SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT = 338000 + TX;
    uint256 constant WIN_INNER_TOURNAMENT = 311000 + TX;
    uint256 constant ELIMINATE_INNER_TOURNAMENT = 147000 + TX;
    uint256 constant SEAL_LEAF_MATCH = 80000 + TX;
    uint256 constant WIN_LEAF_MATCH = 818000 + TX;
}
