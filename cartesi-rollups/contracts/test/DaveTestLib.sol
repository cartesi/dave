// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.22;

import {LibBinaryMerkleTree} from "cartesi-rollups-contracts-3.0.0/src/library/LibBinaryMerkleTree.sol";
import {LibKeccak256} from "cartesi-rollups-contracts-3.0.0/src/library/LibKeccak256.sol";

/// @notice `LibBinaryMerkleTree.merkleRootAfterReplacement` re-exposed as an
/// external function so tests can pass a `calldata` sibling array.
library LibExternalBinaryKeccak256MerkleTree {
    using LibBinaryMerkleTree for bytes32[];

    function merkleRootAfterReplacement(bytes32[] calldata sibs, uint256 nodeIndex, bytes32 node)
        external
        pure
        returns (bytes32)
    {
        return sibs.merkleRootAfterReplacement(nodeIndex, node, LibKeccak256.hashPair);
    }
}

/// @notice Reconstruct the (left, right) children of a commitment from a final
/// machine state hash and its bottom-up proof, as a joining player would.
function getCommitmentChildren(bytes32 machineMerkleRoot, bytes32[] memory proof)
    pure
    returns (bytes32 leftChild, bytes32 rightChild)
{
    leftChild = proof[proof.length - 1];

    rightChild = machineMerkleRoot;
    for (uint256 i; i < proof.length - 1; ++i) {
        rightChild = LibKeccak256.hashPair(proof[i], rightChild);
    }
}
