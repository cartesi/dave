// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "./SmallFullTree.sol";

contract SmallFullTreeProofVerifier {
    function rootAt(
        bytes32 leaf,
        uint64 height,
        uint256 position,
        bytes32[] calldata proof
    ) external pure returns (Tree.Node) {
        return Commitment.getRoot(leaf, height, position, proof);
    }

    function finalRoot(uint64 height, bytes32 leaf, bytes32[] calldata proof)
        external
        pure
        returns (Tree.Node)
    {
        return Commitment.getRootForLastLeaf(height, leaf, proof);
    }

    function rootFromLeaves(Tree.Node[] memory leaves)
        external
        pure
        returns (Tree.Node)
    {
        return SmallFullTree.root(SmallFullTree.buildFromLeaves(leaves));
    }

    function rootFromSeed(bytes32 seed, uint64 height)
        external
        pure
        returns (Tree.Node)
    {
        return SmallFullTree.root(SmallFullTree.build(seed, height));
    }
}

contract SmallFullTreeTest is Test {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    SmallFullTreeProofVerifier internal immutable VERIFIER;

    constructor() {
        VERIFIER = new SmallFullTreeProofVerifier();
    }

    function testEveryCoordinateAndProofThroughHeightEight() public view {
        for (uint64 height = 1; height <= 8; ++height) {
            SmallFullTree.Data memory tree =
                SmallFullTree.build(bytes32(uint256(height)), height);
            assertEq(tree.height(), height);
            assertEq(tree.leafCount(), uint256(1) << height);

            for (uint64 nodeHeight = 1; nodeHeight <= height; ++nodeHeight) {
                uint256 count = uint256(1) << (height - nodeHeight);
                for (uint256 index; index < count; ++index) {
                    (Tree.Node left, Tree.Node right) =
                        tree.children(nodeHeight, index);
                    assertTrue(
                        left.join(right).eq(tree.node(nodeHeight, index))
                    );
                }
            }

            for (uint256 position; position < tree.leafCount(); ++position) {
                Tree.Node computed = VERIFIER.rootAt(
                    Tree.Node.unwrap(tree.leaf(position)),
                    height,
                    position,
                    tree.proof(position)
                );
                assertTrue(computed.eq(tree.root()));
            }

            assertEq(
                Tree.Node.unwrap(tree.leaf(tree.leafCount() - 1)),
                Machine.Hash.unwrap(tree.finalState())
            );
            bytes32[] memory finalProof = tree.finalProof();
            assertEq(finalProof.length, height);
            Tree.Node finalRoot = VERIFIER.finalRoot(
                height, Machine.Hash.unwrap(tree.finalState()), finalProof
            );
            assertTrue(finalRoot.eq(tree.root()));
        }
    }

    function testFirstDivergenceDistinguishesEqualAndDifferentTrees()
        public
        pure
    {
        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), 3);
        SmallFullTree.Data memory same =
            SmallFullTree.build(bytes32(uint256(1)), 3);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), 3);

        (bool found,) = one.firstDivergence(same);
        assertFalse(found);

        uint256 position;
        (found, position) = one.firstDivergence(two);
        assertTrue(found);
        assertEq(position, 0);
    }

    function testCallerLeavesSelectANonzeroDivergence() public view {
        Tree.Node[] memory oneLeaves = new Tree.Node[](8);
        Tree.Node[] memory twoLeaves = new Tree.Node[](8);
        for (uint256 i; i < oneLeaves.length; ++i) {
            Tree.Node leaf = Tree.Node.wrap(keccak256(abi.encode(i)));
            oneLeaves[i] = leaf;
            twoLeaves[i] = leaf;
        }
        twoLeaves[5] = Tree.Node.wrap(keccak256("different"));

        SmallFullTree.Data memory one = SmallFullTree.buildFromLeaves(oneLeaves);
        SmallFullTree.Data memory two = SmallFullTree.buildFromLeaves(twoLeaves);
        (bool found, uint256 position) = one.firstDivergence(two);
        assertTrue(found);
        assertEq(position, 5);
        assertFalse(one.root().eq(two.root()));

        Tree.Node computed = VERIFIER.rootAt(
            Tree.Node.unwrap(two.leaf(position)),
            two.height(),
            position,
            two.proof(position)
        );
        assertTrue(computed.eq(two.root()));
    }

    function testRejectsUnsupportedShapes() public {
        uint256[4] memory counts = [uint256(0), uint256(1), uint256(3), 257];
        for (uint256 i; i < counts.length; ++i) {
            Tree.Node[] memory leaves = new Tree.Node[](counts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    SmallFullTree.InvalidLeafCount.selector, counts[i]
                )
            );
            VERIFIER.rootFromLeaves(leaves);
        }

        vm.expectRevert(
            abi.encodeWithSelector(SmallFullTree.InvalidHeight.selector, 0)
        );
        VERIFIER.rootFromSeed(bytes32(0), 0);

        vm.expectRevert(
            abi.encodeWithSelector(SmallFullTree.InvalidHeight.selector, 9)
        );
        VERIFIER.rootFromSeed(bytes32(0), 9);
    }
}
