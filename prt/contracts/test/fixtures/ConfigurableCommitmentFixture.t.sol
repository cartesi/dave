// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {
    ConfigurableCommitmentFixture
} from "./ConfigurableCommitmentFixture.sol";

contract CommitmentProofVerifier {
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
}

contract ConfigurableCommitmentFixtureTest is
    Test,
    ConfigurableCommitmentFixture
{
    using Tree for Tree.Node;

    uint64 internal constant HEIGHT = 55;
    Machine.Hash internal constant STATE_A =
        Machine.Hash.wrap(bytes32(uint256(0xa)));
    Machine.Hash internal constant STATE_B =
        Machine.Hash.wrap(bytes32(uint256(0xb)));
    Machine.Hash internal constant STATE_C =
        Machine.Hash.wrap(bytes32(uint256(0xc)));

    CommitmentProofVerifier internal immutable VERIFIER;

    constructor() {
        VERIFIER = new CommitmentProofVerifier();
    }

    function setUp() public {
        initializeCommitmentFixture(HEIGHT, STATE_A, STATE_B, STATE_C);
    }

    function testBuildsEveryShapeThroughConfiguredHeight() public view {
        assertEq(fixtureMaxHeight(), HEIGHT);
        assertTrue(sameNode(0).eq(Tree.Node.wrap(Machine.Hash.unwrap(STATE_A))));
        assertTrue(
            rightmostNode(0).eq(Tree.Node.wrap(Machine.Hash.unwrap(STATE_B)))
        );
        assertTrue(
            firstDifferentNode(0)
                .eq(Tree.Node.wrap(Machine.Hash.unwrap(STATE_C)))
        );

        assertFalse(sameNode(HEIGHT).eq(rightmostNode(HEIGHT)));
        assertFalse(sameNode(HEIGHT).eq(secondDifferentNode(HEIGHT)));
        assertFalse(sameNode(HEIGHT).eq(firstDifferentNode(HEIGHT)));
        assertFalse(sameNode(HEIGHT).eq(thirdDifferentNode(HEIGHT)));
        assertFalse(rightmostNode(HEIGHT).eq(secondDifferentNode(HEIGHT)));
        assertFalse(rightmostNode(HEIGHT).eq(firstDifferentNode(HEIGHT)));
        assertFalse(rightmostNode(HEIGHT).eq(thirdDifferentNode(HEIGHT)));
        assertFalse(secondDifferentNode(HEIGHT).eq(firstDifferentNode(HEIGHT)));
        assertFalse(secondDifferentNode(HEIGHT).eq(thirdDifferentNode(HEIGHT)));
        assertFalse(firstDifferentNode(HEIGHT).eq(thirdDifferentNode(HEIGHT)));

        _assertChildren(CommitmentShape.SAME, 1);
        _assertChildren(CommitmentShape.RIGHTMOST_DIFFERENT, 2);
        _assertChildren(CommitmentShape.SECOND_DIFFERENT, HEIGHT);
        _assertChildren(CommitmentShape.FIRST_DIFFERENT, HEIGHT);
        _assertChildren(CommitmentShape.THIRD_DIFFERENT, 1);
        _assertChildren(CommitmentShape.THIRD_DIFFERENT, 2);
        _assertChildren(CommitmentShape.THIRD_DIFFERENT, HEIGHT);
    }

    function testFinalProofsAtHeight55() public view {
        _assertFinalProof(CommitmentShape.SAME);
        _assertFinalProof(CommitmentShape.RIGHTMOST_DIFFERENT);
        _assertFinalProof(CommitmentShape.SECOND_DIFFERENT);
        _assertFinalProof(CommitmentShape.FIRST_DIFFERENT);
        _assertFinalProof(CommitmentShape.THIRD_DIFFERENT);
    }

    function testSecondLastAgreeProofsAtHeight55() public view {
        _assertSecondLastProof(CommitmentShape.SAME, HEIGHT);
        _assertSecondLastProof(CommitmentShape.RIGHTMOST_DIFFERENT, HEIGHT);
        _assertSecondLastProof(CommitmentShape.SECOND_DIFFERENT, HEIGHT);
        _assertSecondLastProof(CommitmentShape.FIRST_DIFFERENT, HEIGHT);
        _assertSecondLastProof(CommitmentShape.THIRD_DIFFERENT, HEIGHT);
    }

    function testFirstDifferentHeightOneProofUsesItsFirstLeaf() public view {
        uint64 height = 1;
        CommitmentShape shape = CommitmentShape.FIRST_DIFFERENT;
        Machine.Hash leaf = secondLastState(shape, height);
        bytes32[] memory proof = agreeProofForSecondLast(shape, height);

        Tree.Node root =
            VERIFIER.rootAt(Machine.Hash.unwrap(leaf), height, 0, proof);
        assertTrue(root.eq(firstDifferentNode(height)));
        assertEq(Machine.Hash.unwrap(leaf), Machine.Hash.unwrap(STATE_C));
    }

    function testSecondDifferentHeightOneUsesItsRightmostState() public view {
        uint64 height = 1;
        CommitmentShape shape = CommitmentShape.SECOND_DIFFERENT;
        Machine.Hash leaf = finalState(shape, height);
        bytes32[] memory proof = finalProof(shape, height);

        Tree.Node root =
            VERIFIER.finalRoot(height, Machine.Hash.unwrap(leaf), proof);
        assertTrue(root.eq(secondDifferentNode(height)));
        assertEq(Machine.Hash.unwrap(leaf), Machine.Hash.unwrap(STATE_B));
    }

    function _assertChildren(CommitmentShape shape, uint64 height)
        internal
        view
    {
        (Tree.Node left, Tree.Node right) = children(shape, height);
        assertTrue(left.join(right).eq(node(shape, height)));
    }

    function _assertFinalProof(CommitmentShape shape) internal view {
        Machine.Hash leaf = finalState(shape, HEIGHT);
        bytes32[] memory proof = finalProof(shape, HEIGHT);

        Tree.Node root =
            VERIFIER.finalRoot(HEIGHT, Machine.Hash.unwrap(leaf), proof);
        assertTrue(root.eq(node(shape, HEIGHT)));
        assertEq(proof.length, HEIGHT);
    }

    function _assertSecondLastProof(CommitmentShape shape, uint64 height)
        internal
        view
    {
        Machine.Hash leaf = secondLastState(shape, height);
        bytes32[] memory proof = agreeProofForSecondLast(shape, height);
        uint256 position = (uint256(1) << height) - 2;

        Tree.Node root =
            VERIFIER.rootAt(Machine.Hash.unwrap(leaf), height, position, proof);
        assertTrue(root.eq(node(shape, height)));
        assertEq(proof.length, height);
    }
}
