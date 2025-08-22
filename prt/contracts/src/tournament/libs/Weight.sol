// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library Weight {
    uint256 constant TX_INTRINSIC_GAS = 21000;

    uint256 constant ADVANCE_MATCH = 65175 + TX_INTRINSIC_GAS;
    uint256 constant WIN_MATCH_BY_TIMEOUT = 86203 + TX_INTRINSIC_GAS;
    uint256 constant ELIMINATE_MATCH_BY_TIMEOUT = 62135 + TX_INTRINSIC_GAS;
    uint256 constant SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT =
        237531 + TX_INTRINSIC_GAS;
    uint256 constant WIN_INNER_TOURNAMENT = 228030 + TX_INTRINSIC_GAS;
    uint256 constant ELIMINATE_INNER_TOURNAMENT = 85183 + TX_INTRINSIC_GAS;
    uint256 constant SEAL_LEAF_MATCH = 57355 + TX_INTRINSIC_GAS;
    uint256 constant WIN_LEAF_MATCH = 102728 + TX_INTRINSIC_GAS;
}
