// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

/// @dev Test-only complete Merkle trees for small injected geometries.
library SmallFullTree {
    using SmallFullTree for Data;
    using Tree for Tree.Node;

    uint64 internal constant MAX_HEIGHT = 8;

    error InvalidHeight(uint64 height);
    error InvalidLeafCount(uint256 count);

    struct Data {
        // Entry levels[h][i] is subtree i of height h.
        Tree.Node[][] levels;
    }

    function build(bytes32 seed, uint64 treeHeight)
        internal
        pure
        returns (Data memory tree)
    {
        if (treeHeight == 0 || treeHeight > MAX_HEIGHT) {
            revert InvalidHeight(treeHeight);
        }

        uint256 count = uint256(1) << treeHeight;
        Tree.Node[] memory leaves = new Tree.Node[](count);
        for (uint256 i; i < count; ++i) {
            leaves[i] = Tree.Node.wrap(keccak256(abi.encode(seed, i)));
        }
        return buildFromLeaves(leaves);
    }

    function buildFromLeaves(Tree.Node[] memory leaves)
        internal
        pure
        returns (Data memory tree)
    {
        uint256 count = leaves.length;
        if (
            count < 2 || count > (uint256(1) << MAX_HEIGHT)
                || (count & (count - 1)) != 0
        ) {
            revert InvalidLeafCount(count);
        }

        uint64 treeHeight;
        for (uint256 remaining = count; remaining > 1; remaining >>= 1) {
            ++treeHeight;
        }
        tree.levels = new Tree.Node[][](treeHeight + 1);
        tree.levels[0] = leaves;

        for (uint64 level = 1; level <= treeHeight; ++level) {
            count /= 2;
            tree.levels[level] = new Tree.Node[](count);
            for (uint256 i; i < count; ++i) {
                tree.levels[level][i] = tree.levels[level
                        - 1][2 * i].join(tree.levels[level - 1][2 * i + 1]);
            }
        }
    }

    function height(Data memory tree) internal pure returns (uint64) {
        if (tree.levels.length <= 1) revert InvalidHeight(0);
        return uint64(tree.levels.length - 1);
    }

    function leafCount(Data memory tree) internal pure returns (uint256) {
        return tree.levels[0].length;
    }

    function root(Data memory tree) internal pure returns (Tree.Node) {
        return tree.levels[tree.height()][0];
    }

    function node(Data memory tree, uint64 nodeHeight, uint256 index)
        internal
        pure
        returns (Tree.Node)
    {
        return tree.levels[nodeHeight][index];
    }

    function leaf(Data memory tree, uint256 position)
        internal
        pure
        returns (Tree.Node)
    {
        return tree.levels[0][position];
    }

    function finalState(Data memory tree) internal pure returns (Machine.Hash) {
        return tree.leaf(tree.leafCount() - 1).toMachineHash();
    }

    function children(Data memory tree, uint64 nodeHeight, uint256 index)
        internal
        pure
        returns (Tree.Node left, Tree.Node right)
    {
        if (nodeHeight == 0 || nodeHeight > tree.height()) {
            revert InvalidHeight(nodeHeight);
        }
        left = tree.levels[nodeHeight - 1][2 * index];
        right = tree.levels[nodeHeight - 1][2 * index + 1];
    }

    function proof(Data memory tree, uint256 position)
        internal
        pure
        returns (bytes32[] memory siblings)
    {
        uint64 treeHeight = tree.height();
        siblings = new bytes32[](treeHeight);
        for (uint64 level; level < treeHeight; ++level) {
            uint256 siblingIndex = (position >> level) ^ 1;
            siblings[level] = Tree.Node.unwrap(tree.levels[level][siblingIndex]);
        }
    }

    function finalProof(Data memory tree)
        internal
        pure
        returns (bytes32[] memory)
    {
        return tree.proof(tree.leafCount() - 1);
    }

    function firstDivergence(Data memory one, Data memory two)
        internal
        pure
        returns (bool found, uint256 position)
    {
        uint256 count = one.leafCount();
        assert(count == two.leafCount());
        for (uint256 i; i < count; ++i) {
            if (!one.leaf(i).eq(two.leaf(i))) {
                return (true, i);
            }
        }
    }
}
