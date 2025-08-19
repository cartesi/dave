// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library Weight {
    uint256 constant ADVANCE_MATCH = 1;
    uint256 constant WIN_MATCH_BY_TIMEOUT = 1;
    uint256 constant ELIMINATE_MATCH_BY_TIMEOUT = 1;
    uint256 constant SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT = 3;
    uint256 constant WIN_INNER_TOURNAMENT = 1;
    uint256 constant ELIMINATE_INNER_TOURNAMENT = 1;
    uint256 constant SEAL_LEAF_MATCH = 1;
    uint256 constant WIN_LEAF_MATCH = 2;
}
