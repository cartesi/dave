// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/ArbitrationConstants.sol";
import "prt-contracts/types/Tree.sol";
import "prt-contracts/types/Machine.sol";

library Commitment {
    using Tree for Tree.Node;
    using Commitment for Tree.Node;

    struct Arguments {
        Machine.Hash initialHash;
        uint256 startCycle;
        uint64 log2step;
        uint64 height;
    }

    function toCycle(Arguments memory args, uint256 leafPosition)
        internal
        pure
        returns (uint256)
    {
        uint256 step = 1 << args.log2step;
        return args.startCycle + (leafPosition * step);
    }

    error CommitmentStateMismatch(Tree.Node received, Tree.Node expected);
    error CommitmentFinalStateMismatch(Tree.Node received, Tree.Node expected);
    error CommitmentProofWrongSize(uint256 received, uint256 expected);

    function requireState(
        Tree.Node commitment,
        uint64 treeHeight,
        uint256 position,
        Machine.Hash state,
        bytes32[] calldata hashProof
    ) internal pure {
        Tree.Node expectedCommitment = getRoot(
            Machine.Hash.unwrap(state), treeHeight, position, hashProof
        );

        require(
            commitment.eq(expectedCommitment),
            CommitmentStateMismatch(commitment, expectedCommitment)
        );
    }

    function isEven(uint256 x) private pure returns (bool) {
        return x % 2 == 0;
    }

    error LengthMismatch(uint64 treeHeight, uint64 siblingsLength);

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
            if (isEven(position >> i)) {
                leaf = keccak256(abi.encodePacked(leaf, siblings[i]));
            } else {
                leaf = keccak256(abi.encodePacked(siblings[i], leaf));
            }
        }

        return Tree.Node.wrap(leaf);
    }

    function requireFinalState(
        Tree.Node commitment,
        uint64 treeHeight,
        Machine.Hash finalState,
        bytes32[] calldata hashProof
    ) internal pure {
        Tree.Node expectedCommitment =
            getRootForLastLeaf(
                treeHeight, Machine.Hash.unwrap(finalState), hashProof
            );

        require(
            commitment.eq(expectedCommitment),
            CommitmentFinalStateMismatch(commitment, expectedCommitment)
        );
    }

    function getRootForLastLeaf(
        uint64 treeHeight,
        bytes32 leaf,
        bytes32[] calldata siblings
    ) internal pure returns (Tree.Node) {
        require(
            treeHeight == siblings.length,
            CommitmentProofWrongSize(treeHeight, siblings.length)
        );

        for (uint256 i = 0; i < treeHeight; i++) {
            leaf = keccak256(abi.encodePacked(siblings[i], leaf));
        }

        return Tree.Node.wrap(leaf);
    }
}
