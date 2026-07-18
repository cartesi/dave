// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

/// @notice Configured gas-unit allocations used to cap action refunds.
/// @dev For reviewed successful paths, each allocation includes the fixed
/// unmetered allowance, the largest measured modifier-body cost, and explicit
/// headroom. It is not a whole-transaction or receipt-exact gas bound. Economic
/// principal and fee policy live in `Bond`.
library Gas {
    /// @notice Fixed per-action allowance for work outside the gas snapshots.
    /// @dev This is policy, not measured transaction-intrinsic gas. A batch
    /// receives it once for every successful refundable action.
    uint256 constant TX = 25000;

    uint256 constant ADVANCE_MATCH = 101000 + TX;
    uint256 constant WIN_MATCH_BY_TIMEOUT = 235000 + TX;
    uint256 constant ELIMINATE_MATCH_BY_TIMEOUT = 110000 + TX;
    uint256 constant SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT = 339000 + TX;
    uint256 constant WIN_INNER_TOURNAMENT = 312000 + TX;
    uint256 constant ELIMINATE_INNER_TOURNAMENT = 148000 + TX;
    uint256 constant SEAL_LEAF_MATCH = 82000 + TX;
    uint256 constant WIN_LEAF_MATCH = 102728 + TX;
}
