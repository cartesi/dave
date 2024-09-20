// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

library MerkleConstants {
    uint256 constant HASH_SIZE = 32;
    uint256 constant LOG2_MEMORY_SIZE = 64;
    uint256 constant LOG2_WORD_SIZE = 5;
    uint256 constant TREE_HEIGHT = LOG2_MEMORY_SIZE - LOG2_WORD_SIZE;
}
