// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {
    Hashes
} from "@openzeppelin-contracts-5.5.0/utils/cryptography/Hashes.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

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

    function requireState(
        Tree.Node commitment,
        uint64 treeHeight,
        uint256 position,
        Machine.Hash state,
        bytes32[] calldata hashProof
    ) internal pure {
        Tree.Node computedCommitment = getRoot(
            Machine.Hash.unwrap(state), treeHeight, position, hashProof
        );

        require(
            commitment.eq(computedCommitment),
            ITournament.CommitmentStateMismatch(commitment, computedCommitment)
        );
    }

    function isEven(uint256 x) private pure returns (bool) {
        return x % 2 == 0;
    }

    function getRoot(
        bytes32 leaf,
        uint64 treeHeight,
        uint256 position,
        bytes32[] calldata siblings
    ) internal pure returns (Tree.Node) {
        uint64 siblingsLength = uint64(siblings.length);
        require(
            treeHeight == siblingsLength,
            ITournament.CommitmentProofWrongSize(treeHeight, siblingsLength)
        );

        for (uint256 i = 0; i < treeHeight; i++) {
            if (isEven(position >> i)) {
                leaf = Hashes.efficientKeccak256(leaf, siblings[i]);
            } else {
                leaf = Hashes.efficientKeccak256(siblings[i], leaf);
            }
        }

        return Tree.Node.wrap(leaf);
    }

    function getRootChildrenFromFinalStateProof(
        uint64 treeHeight,
        Machine.Hash finalState,
        bytes32[] calldata siblings
    ) internal pure returns (Tree.Node left, Tree.Node right) {
        require(
            treeHeight == siblings.length && treeHeight >= 1,
            ITournament.CommitmentProofWrongSize(treeHeight, siblings.length)
        );

        bytes32 leaf = Machine.Hash.unwrap(finalState);
        for (uint256 i = 0; i < treeHeight - 1; i++) {
            leaf = Hashes.efficientKeccak256(siblings[i], leaf);
        }

        return (Tree.Node.wrap(siblings[treeHeight - 1]), Tree.Node.wrap(leaf));
    }
}
