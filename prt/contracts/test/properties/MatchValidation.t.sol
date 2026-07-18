// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "../fixtures/SmallFullTree.sol";

library MatchValidationMutation {
    function advance(
        Match.State storage state,
        Tree.Node leftNode,
        Tree.Node rightNode,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) external {
        Match.advanceBisection(
            state, leftNode, rightNode, newLeftNode, newRightNode
        );
    }

    function seal(
        Match.State storage state,
        Commitment.Arguments memory args,
        Match.Id calldata id,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    ) external {
        Match.sealDivergence(
            state, args, id, leftLeaf, rightLeaf, agreeState, agreeStateProof
        );
    }
}

contract MatchValidationTest is Test {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x11)));
    Machine.Hash internal constant WRONG_AGREE_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x12)));

    Match.State private _state;

    function testAdvanceRejectsInvalidCurrentParentChildrenWithoutMutation()
        public
    {
        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), 2);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), 2);
        (Commitment.Arguments memory args,) = _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        (Tree.Node newLeft, Tree.Node newRight) = one.children(1, 0);
        Tree.Node invalidLeft = _differentNode(oneLeft);
        Match.State memory beforeState = _state;

        vm.expectRevert(
            _invalidChildrenError(_state.otherParent, invalidLeft, oneRight)
        );
        MatchValidationMutation.advance(
            _state, invalidLeft, oneRight, newLeft, newRight
        );

        _assertStateEquals(beforeState);
    }

    function testAdvanceLeftRejectsInvalidSelectedChildrenWithoutMutation()
        public
    {
        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), 2);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), 2);
        (Commitment.Arguments memory args,) = _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        (Tree.Node twoLeft,) = two.children(args.height, 0);
        assertFalse(oneLeft.eq(twoLeft));

        (Tree.Node newLeft, Tree.Node newRight) = one.children(1, 0);
        Tree.Node invalidRight = _differentNode(newRight);
        Match.State memory beforeState = _state;

        vm.expectRevert(_invalidChildrenError(oneLeft, newLeft, invalidRight));
        MatchValidationMutation.advance(
            _state, oneLeft, oneRight, newLeft, invalidRight
        );

        _assertStateEquals(beforeState);
    }

    function testAdvanceRightRejectsInvalidSelectedChildrenWithoutMutation()
        public
    {
        SmallFullTree.Data memory one =
            _fourLeafTree(_node(0x10), _node(0x11), _node(0x12), _node(0x13));
        SmallFullTree.Data memory two =
            _fourLeafTree(_node(0x10), _node(0x11), _node(0x22), _node(0x23));
        (Commitment.Arguments memory args,) = _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(args.height, 0);
        assertTrue(oneLeft.eq(twoLeft));
        assertFalse(oneRight.eq(twoRight));

        (Tree.Node newLeft, Tree.Node newRight) = one.children(1, 1);
        Tree.Node invalidLeft = _differentNode(newLeft);
        Match.State memory beforeState = _state;

        vm.expectRevert(_invalidChildrenError(oneRight, invalidLeft, newRight));
        MatchValidationMutation.advance(
            _state, oneLeft, oneRight, invalidLeft, newRight
        );

        _assertStateEquals(beforeState);
    }

    function testSealRejectsInvalidCurrentParentChildrenWithoutMutation()
        public
    {
        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), 1);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), 1);
        (Commitment.Arguments memory args, Match.Id memory id) =
            _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        Tree.Node invalidRight = _differentNode(oneRight);
        Match.State memory beforeState = _state;

        vm.expectRevert(
            _invalidChildrenError(_state.otherParent, oneLeft, invalidRight)
        );
        MatchValidationMutation.seal(
            _state,
            args,
            id,
            oneLeft,
            invalidRight,
            INITIAL_STATE,
            new bytes32[](0)
        );

        _assertStateEquals(beforeState);
    }

    function testSealAtPositionZeroRejectsWrongInitialAgreeWithoutMutation()
        public
    {
        SmallFullTree.Data memory one = _twoLeafTree(_node(0x10), _node(0x20));
        SmallFullTree.Data memory two = _twoLeafTree(_node(0x11), _node(0x20));
        (Commitment.Arguments memory args, Match.Id memory id) =
            _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        (Tree.Node twoLeft,) = two.children(args.height, 0);
        assertFalse(oneLeft.eq(twoLeft));
        Match.State memory beforeState = _state;

        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.IncorrectAgreeState.selector,
                Machine.Hash.unwrap(INITIAL_STATE),
                Machine.Hash.unwrap(WRONG_AGREE_STATE)
            )
        );
        MatchValidationMutation.seal(
            _state,
            args,
            id,
            oneLeft,
            oneRight,
            WRONG_AGREE_STATE,
            new bytes32[](0)
        );

        _assertStateEquals(beforeState);
    }

    function testSealRejectsWrongProofLengthAtNonzeroPositionWithoutMutation()
        public
    {
        SmallFullTree.Data memory one =
            _fourLeafTree(_node(0x10), _node(0x11), _node(0x12), _node(0x13));
        SmallFullTree.Data memory two =
            _fourLeafTree(_node(0x10), _node(0x11), _node(0x12), _node(0x23));
        (Commitment.Arguments memory args, Match.Id memory id) =
            _initialize(one, two);

        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(args.height, 0);
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(args.height, 0);
        assertTrue(oneLeft.eq(twoLeft));
        assertFalse(oneRight.eq(twoRight));

        (Tree.Node oneRightLeft, Tree.Node oneRightRight) = one.children(1, 1);
        MatchValidationMutation.advance(
            _state, oneLeft, oneRight, oneRightLeft, oneRightRight
        );
        assertEq(_state.currentHeight, 1);
        assertEq(_state.runningLeafPosition, 2);

        (Tree.Node twoRightLeft, Tree.Node twoRightRight) = two.children(1, 1);
        assertTrue(twoRightLeft.eq(oneRightLeft));
        assertFalse(twoRightRight.eq(oneRightRight));
        Match.State memory beforeState = _state;
        bytes32[] memory shortProof = new bytes32[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentProofWrongSize.selector,
                uint256(args.height),
                shortProof.length
            )
        );
        MatchValidationMutation.seal(
            _state,
            args,
            id,
            twoRightLeft,
            twoRightRight,
            twoRightLeft.toMachineHash(),
            shortProof
        );

        _assertStateEquals(beforeState);
    }

    function _initialize(
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal returns (Commitment.Arguments memory args, Match.Id memory id) {
        uint64 height = one.height();
        assertEq(height, two.height());
        args = Commitment.Arguments({
            initialHash: INITIAL_STATE,
            startCycle: 17,
            log2step: 3,
            height: height
        });
        id = Match.Id({commitmentOne: one.root(), commitmentTwo: two.root()});
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(height, 0);
        (, Match.State memory state) = Match.create(
            args, id.commitmentOne, id.commitmentTwo, twoLeft, twoRight
        );
        _state = state;
    }

    function _twoLeafTree(Tree.Node zero, Tree.Node one)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory leaves = new Tree.Node[](2);
        leaves[0] = zero;
        leaves[1] = one;
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _fourLeafTree(
        Tree.Node zero,
        Tree.Node one,
        Tree.Node two,
        Tree.Node three
    ) internal pure returns (SmallFullTree.Data memory) {
        Tree.Node[] memory leaves = new Tree.Node[](4);
        leaves[0] = zero;
        leaves[1] = one;
        leaves[2] = two;
        leaves[3] = three;
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _assertStateEquals(Match.State memory expected) internal view {
        assertEq(
            Tree.Node.unwrap(_state.otherParent),
            Tree.Node.unwrap(expected.otherParent)
        );
        assertEq(
            Tree.Node.unwrap(_state.leftNode),
            Tree.Node.unwrap(expected.leftNode)
        );
        assertEq(
            Tree.Node.unwrap(_state.rightNode),
            Tree.Node.unwrap(expected.rightNode)
        );
        assertEq(_state.runningLeafPosition, expected.runningLeafPosition);
        assertEq(_state.currentHeight, expected.currentHeight);
        assertEq(_state.isInit, expected.isInit);
    }

    function _invalidChildrenError(
        Tree.Node expectedParent,
        Tree.Node leftChild,
        Tree.Node rightChild
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ITournament.InvalidChildrenNodes.selector,
            Tree.Node.unwrap(expectedParent),
            Tree.Node.unwrap(leftChild),
            Tree.Node.unwrap(rightChild)
        );
    }

    function _differentNode(Tree.Node node) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(Tree.Node.unwrap(node) ^ bytes32(uint256(1)));
    }

    function _node(uint256 value) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(bytes32(value));
    }
}
