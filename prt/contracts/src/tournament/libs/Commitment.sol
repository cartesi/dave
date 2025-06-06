// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/CanonicalConstants.sol";
import "prt-contracts/types/Tree.sol";
import "prt-contracts/types/Machine.sol";

// Add documentation: What is a commitment?
// This library deals mainly with tree nodes,
// so we could move these functions to the Tree library.
library Commitment {
    using Tree for Tree.Node;
    using Commitment for Tree.Node;

    error CommitmentMismatch(Tree.Node received, Tree.Node expected);

    // Rename as requireValidStateCommitment?
    function requireState(
        Tree.Node commitment,
        uint64 treeHeight,
        uint256 position,
        Machine.Hash state,
        bytes32[] calldata hashProof
    ) internal pure {
        Tree.Node expectedCommitment =
            getRoot(Machine.Hash.unwrap(state), treeHeight, position, hashProof);

        require(
            commitment.eq(expectedCommitment),
            CommitmentMismatch(commitment, expectedCommitment)
        );
    }

    // Move this to a math library?
    function isEven(uint256 x) private pure returns (bool) {
        return x % 2 == 0;
    }

    // Rename as SiblingsArrayLengthMismatch?
    error LengthMismatch(uint64 treeHeight, uint64 siblingsLength);

    // Rename as getRootAfterLeafReplacement?
    function getRoot(
        bytes32 leaf,
        uint64 treeHeight,
        uint256 position,
        bytes32[] calldata siblings
    ) internal pure returns (Tree.Node) {
        uint64 siblingsLength = uint64(siblings.length);
        require(
            treeHeight == siblingsLength,
            LengthMismatch(treeHeight, siblingsLength)
        );

        for (uint256 i = 0; i < treeHeight; i++) {
            // Gas optimization opportunity:
            // See cartesi-rollups/contracts/src/Merkle.sol:Merkle.join
            //
            // I'm seeing a lot of intersection with the code over at
            // cartesi-rollups/contracts. Maybe we could define these
            // Merkle primitives here so that we could use them there?
            if (isEven(position >> i)) {
                leaf = keccak256(abi.encodePacked(leaf, siblings[i]));
            } else {
                leaf = keccak256(abi.encodePacked(siblings[i], leaf));
            }
        }

        return Tree.Node.wrap(leaf);
    }

    // Rename as requireValidFinalStateCommitment?
    function requireFinalState(
        Tree.Node commitment,
        uint64 treeHeight,
        Machine.Hash finalState,
        bytes32[] calldata hashProof
    ) internal pure {
        Tree.Node expectedCommitment = getRootForLastLeaf(
            treeHeight, Machine.Hash.unwrap(finalState), hashProof
        );

        // Raise CommitmentMismatch instead?
        require(
            commitment.eq(expectedCommitment),
            "commitment last state doesn't match"
        );
    }

    // Rename as getRootAfterLastLeafReplacement?
    // Reorder parameters to look similar to the other function:
    // leaf, treeHeight, siblings
    function getRootForLastLeaf(
        uint64 treeHeight,
        bytes32 leaf,
        bytes32[] calldata siblings
    ) internal pure returns (Tree.Node) {
        // Raise LengthMismatch instead?
        assert(treeHeight == siblings.length);

        for (uint256 i = 0; i < treeHeight; i++) {
            // Gas optimization opportunity:
            // See cartesi-rollups/contracts/src/Merkle.sol:Merkle.join
            leaf = keccak256(abi.encodePacked(siblings[i], leaf));
        }

        return Tree.Node.wrap(leaf);
    }
}
