// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/ArbitrationConstants.sol";
import "prt-contracts/types/Tree.sol";
import "prt-contracts/types/Machine.sol";

import "prt-contracts/tournament/libs/Commitment.sol";

/// @notice Implements functionalities to advance a match, until the point where divergence is found.
library Match {
    using Tree for Tree.Node;
    using Match for Id;
    using Match for IdHash;
    using Match for State;
    using Machine for Machine.Hash;
    using Commitment for Tree.Node;
    using Commitment for Commitment.Arguments;

    //
    // Events
    //
    event MatchAdvanced(
        Match.IdHash indexed matchIdHash, Tree.Node otherParent, Tree.Node left
    );

    //
    // Id
    //
    struct Id {
        Tree.Node commitmentOne;
        Tree.Node commitmentTwo;
    }

    //
    // IdHash
    //
    type IdHash is bytes32;

    IdHash constant ZERO_ID = IdHash.wrap(bytes32(0x0));

    function hashFromId(Id memory id) internal pure returns (IdHash) {
        return IdHash.wrap(keccak256(abi.encode(id)));
    }

    function isZero(IdHash idHash) internal pure returns (bool) {
        return IdHash.unwrap(idHash) == 0x0;
    }

    function eq(IdHash left, IdHash right) internal pure returns (bool) {
        bytes32 l = IdHash.unwrap(left);
        bytes32 r = IdHash.unwrap(right);
        return l == r;
    }

    function requireEq(IdHash left, IdHash right) internal pure {
        require(left.eq(right), "matches are not equal");
    }

    function requireExist(IdHash idHash) internal pure {
        require(!idHash.isZero(), "match doesn't exist");
    }

    //
    // State
    //
    struct State {
        Tree.Node otherParent;
        Tree.Node leftNode;
        Tree.Node rightNode;
        // Once match is done, leftNode and rightNode change meaning
        // and contains contested final states.
        uint256 runningLeafPosition;
        uint64 currentHeight;
        bool isInit;
    }

    // uint64 log2step; // constant
    // uint64 height; // constant

    function createMatch(
        Commitment.Arguments memory args,
        Tree.Node one,
        Tree.Node two,
        Tree.Node leftNodeOfTwo,
        Tree.Node rightNodeOfTwo
    ) internal pure returns (IdHash, State memory) {
        assert(two.verify(leftNodeOfTwo, rightNodeOfTwo));

        Id memory matchId = Id(one, two);

        State memory state = State({
            otherParent: one,
            leftNode: leftNodeOfTwo,
            rightNode: rightNodeOfTwo,
            runningLeafPosition: 0,
            currentHeight: args.height,
            isInit: true
        });

        return (matchId.hashFromId(), state);
    }

    function advanceMatch(
        State storage state,
        Id calldata id,
        Tree.Node leftNode,
        Tree.Node rightNode,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) internal {
        state.requireParentHasChildren(leftNode, rightNode);

        if (!state.agreesOnLeftNode(leftNode)) {
            // go down left in Commitment tree
            leftNode.requireChildren(newLeftNode, newRightNode);
            state._goDownLeftTree(newLeftNode, newRightNode);
        } else {
            // go down right in Commitment tree
            rightNode.requireChildren(newLeftNode, newRightNode);
            state._goDownRightTree(newLeftNode, newRightNode);
        }

        emit MatchAdvanced(id.hashFromId(), state.otherParent, state.leftNode);
    }

    error IncorrectAgreeState(
        Machine.Hash initialState, Machine.Hash agreeState
    );

    function sealMatch(
        State storage state,
        Commitment.Arguments memory args,
        Id calldata id,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    )
        internal
        returns (Machine.Hash divergentStateOne, Machine.Hash divergentStateTwo)
    {
        state.requireParentHasChildren(leftLeaf, rightLeaf);

        if (!state.agreesOnLeftNode(leftLeaf)) {
            // Divergence is in the left leaf!
            (divergentStateOne, divergentStateTwo) =
                state._setDivergenceOnLeftLeaf(args.height, leftLeaf);
        } else {
            // Divergence is in the right leaf!
            (divergentStateOne, divergentStateTwo) =
                state._setDivergenceOnRightLeaf(args.height, rightLeaf);
        }

        // Prove agree hash is in commitment
        if (state.runningLeafPosition == 0) {
            require(
                agreeState.eq(args.initialHash),
                IncorrectAgreeState(args.initialHash, agreeState)
            );
        } else {
            Tree.Node commitment;
            if (args.height % 2 == 1) {
                commitment = id.commitmentOne;
            } else {
                commitment = id.commitmentTwo;
            }

            commitment.requireState(
                args.height,
                state.runningLeafPosition - 1,
                agreeState,
                agreeStateProof
            );
        }

        state._setAgreeState(agreeState);
    }

    //
    // View methods
    //
    function exists(State memory state) internal pure returns (bool) {
        return state.isInit;
    }

    function isFinished(State memory state) internal pure returns (bool) {
        return state.currentHeight == 0;
    }

    function canBeFinalized(State memory state) internal pure returns (bool) {
        return state.currentHeight == 1;
    }

    function canBeAdvanced(State memory state) internal pure returns (bool) {
        return state.currentHeight > 1;
    }

    function agreesOnLeftNode(State memory state, Tree.Node newLeftNode)
        internal
        pure
        returns (bool)
    {
        return newLeftNode.eq(state.leftNode);
    }

    function toCycle(State memory state, Commitment.Arguments memory args)
        internal
        pure
        returns (uint256)
    {
        return args.toCycle(state.runningLeafPosition);
    }

    function getDivergence(
        State memory state,
        Commitment.Arguments memory args
    )
        internal
        pure
        returns (
            Machine.Hash agreeHash,
            uint256 agreeCycle,
            Machine.Hash finalStateOne,
            Machine.Hash finalStateTwo
        )
    {
        assert(state.currentHeight == 0);
        agreeHash = Machine.Hash.wrap(Tree.Node.unwrap(state.otherParent));
        agreeCycle = state.toCycle(args);

        if (state.runningLeafPosition % 2 == 0) {
            // divergence was set on left leaf
            (finalStateOne, finalStateTwo) =
                _getDivergenceOnLeftLeaf(state, args.height);
        } else {
            // divergence was set on right leaf
            (finalStateOne, finalStateTwo) =
                _getDivergenceOnRightLeaf(state, args.height);
        }
    }

    //
    // Requires
    //
    function requireExist(State memory state) internal pure {
        require(state.exists(), "match does not exist");
    }

    function requireIsFinished(State memory state) internal pure {
        require(state.isFinished(), "match is not finished");
    }

    function requireCanBeFinalized(State memory state) internal pure {
        require(state.canBeFinalized(), "match is not ready to be finalized");
    }

    function requireCanBeAdvanced(State memory state) internal pure {
        require(state.canBeAdvanced(), "match can't be advanced");
    }

    function requireParentHasChildren(
        State memory state,
        Tree.Node leftNode,
        Tree.Node rightNode
    ) internal pure {
        state.otherParent.requireChildren(leftNode, rightNode);
    }

    //
    // Private
    //
    function _goDownLeftTree(
        State storage state,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) internal {
        assert(state.currentHeight > 1);
        state.otherParent = state.leftNode;
        state.leftNode = newLeftNode;
        state.rightNode = newRightNode;

        state.currentHeight--;
    }

    function _goDownRightTree(
        State storage state,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) internal {
        assert(state.currentHeight > 1);
        state.otherParent = state.rightNode;
        state.leftNode = newLeftNode;
        state.rightNode = newRightNode;

        state.currentHeight--;
        state.runningLeafPosition += 1 << state.currentHeight;
    }

    function _setDivergenceOnLeftLeaf(
        State storage state,
        uint64 height,
        Tree.Node leftLeaf
    )
        internal
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        assert(state.currentHeight == 1);
        state.rightNode = leftLeaf;
        state.currentHeight = 0;

        (finalStateOne, finalStateTwo) = _getDivergenceOnLeftLeaf(state, height);
    }

    function _setDivergenceOnRightLeaf(
        State storage state,
        uint64 height,
        Tree.Node rightLeaf
    )
        internal
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        assert(state.currentHeight == 1);
        state.leftNode = rightLeaf;
        state.currentHeight = 0;
        state.runningLeafPosition += 1;

        (finalStateOne, finalStateTwo) =
            _getDivergenceOnRightLeaf(state, height);
    }

    function _getDivergenceOnLeftLeaf(State memory state, uint64 height)
        internal
        pure
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        if (height % 2 == 0) {
            finalStateOne = state.leftNode.toMachineHash();
            finalStateTwo = state.rightNode.toMachineHash();
        } else {
            finalStateOne = state.rightNode.toMachineHash();
            finalStateTwo = state.leftNode.toMachineHash();
        }
    }

    function _getDivergenceOnRightLeaf(State memory state, uint64 height)
        internal
        pure
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        if (height % 2 == 0) {
            finalStateOne = state.rightNode.toMachineHash();
            finalStateTwo = state.leftNode.toMachineHash();
        } else {
            finalStateOne = state.leftNode.toMachineHash();
            finalStateTwo = state.rightNode.toMachineHash();
        }
    }

    function _setAgreeState(State storage state, Machine.Hash initialState)
        internal
    {
        assert(state.currentHeight == 0);
        state.otherParent = Tree.Node.wrap(Machine.Hash.unwrap(initialState));
    }
}
