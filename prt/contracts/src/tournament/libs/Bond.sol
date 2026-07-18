// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Gas} from "prt-contracts/tournament/libs/Gas.sol";

/// @notice Economic policy and configured work-reserve accounting for one join.
/// @dev The Sybil principal is deliberately independent of gas allocations.
library Bond {
    /// @notice Inherited behavior checkpoint, not a security-calibrated value.
    uint256 constant SYBIL_PRINCIPAL = 0.00450875 ether;

    uint256 constant WORK_PRICE_CAP = 50 gwei;
    uint256 constant PRIORITY_FEE_CAP = 10 gwei;

    /// @notice Maximum gas available to recipient code during an ETH payment.
    /// @dev EIP-150 may reduce this ceiling when the caller has too little gas.
    uint256 constant PAYMENT_CALLBACK_GAS_LIMIT = 50_000;

    /// @dev Nonzero-value CALL adds a 2,300-gas stipend to this gas operand.
    uint256 constant PAYMENT_CALL_GAS = PAYMENT_CALLBACK_GAS_LIMIT - 2_300;

    /// @notice Largest configured terminal allocation shared by every level.
    function terminalAllocation() internal pure returns (uint256) {
        uint256 leaf = Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH;
        uint256 inner = Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            + Gas.WIN_INNER_TOURNAMENT;
        return leaf > inner ? leaf : inner;
    }

    /// @notice Configured refundable work for one height-`height` match.
    /// @dev A valid positive-height match advances at most `height - 1` times.
    function matchWorkAllocation(uint64 height)
        internal
        pure
        returns (uint256)
    {
        // Subtracting after adding the terminal allocation also preserves the
        // former height-zero value. Zero is invalid geometry, but runtime
        // validation is a separate change.
        return uint256(height) * Gas.ADVANCE_MATCH + terminalAllocation()
            - Gas.ADVANCE_MATCH;
    }

    function bondValue(uint64 height) internal pure returns (uint256) {
        return SYBIL_PRINCIPAL + matchWorkAllocation(height) * WORK_PRICE_CAP;
    }

    function actionRefundCap(uint256 gasAllocation)
        internal
        pure
        returns (uint256)
    {
        return gasAllocation * WORK_PRICE_CAP;
    }
}
