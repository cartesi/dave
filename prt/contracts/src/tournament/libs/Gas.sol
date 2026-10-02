// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

/// @notice Configured gas-unit allocations used to cap action refunds.
/// @dev Reviewed allocations include the fixed unmetered allowance, the
/// calldata charge, measured modifier-body cost, and explicit headroom.
/// `WIN_LEAF_MATCH` is a provisional subsidy selected from the maximum
/// canonical InputBox reference witness, not a bound across all valid proofs
/// or transitions. No allocation is a whole-transaction or receipt-exact gas
/// bound. Work-price and payment policy live in `Bond`.
library Gas {
    /// @notice Fixed per-action allowance for work outside the gas snapshots.
    /// @dev This is policy, not measured transaction-intrinsic gas. A batch
    /// receives it once for every successful refundable action.
    uint256 constant TX = 25000;

    /// @notice Refunded units per byte of the action's calldata.
    /// @dev The EIP-2028 nonzero-byte price, an upper bound on standard
    /// calldata pricing. It makes the leaf proof, whose calldata grows with
    /// the input, subsidized with the rest of the action. Padding can lift a
    /// refund toward its allocation but never past it, which the reserve
    /// argument already assumes. A transaction priced by the EIP-7623 floor
    /// pays more per byte than this.
    uint256 constant CALLDATA_BYTE = 16;

    uint256 constant ADVANCE_MATCH = 103000 + TX;
    uint256 constant WIN_MATCH_BY_TIMEOUT = 238000 + TX;
    uint256 constant ELIMINATE_MATCH_BY_TIMEOUT = 110000 + TX;
    uint256 constant SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT = 367000 + TX;
    uint256 constant WIN_INNER_TOURNAMENT = 273000 + TX;
    uint256 constant ELIMINATE_INNER_TOURNAMENT = 135000 + TX;
    uint256 constant SEAL_LEAF_MATCH = 127000 + TX;
    uint256 constant WIN_LEAF_MATCH = 5_543_000;
}
