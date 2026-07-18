// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "prt-contracts/ITournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @notice Advances alternating bisection until the first divergent leaf is
/// sealed.
/// @dev `State` preserves a phase-overloaded external tuple. New raw-state
/// readers should use the derived phase and phase-specific views instead of
/// interpreting slots directly.
library Match {
    using Tree for Tree.Node;
    using Match for Id;
    using Match for State;
    using Machine for Machine.Hash;
    using Commitment for Tree.Node;
    using Commitment for Commitment.Arguments;

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

    function hashFromId(Id memory id) internal pure returns (IdHash) {
        return IdHash.wrap(keccak256(abi.encode(id)));
    }

    //
    // State
    //
    /// @dev Before sealing, the node fields identify the revealing parent and
    /// waiting side's children. After sealing, they encode the agree state and
    /// divergent leaves. The running position is even during bisection; after
    /// sealing its low bit records the final branch.
    struct State {
        Tree.Node otherParent;
        Tree.Node leftNode;
        Tree.Node rightNode;
        uint256 runningLeafPosition;
        uint64 currentHeight;
        bool isInit;
    }

    enum Phase {
        UNINITIALIZED,
        BISECTING,
        READY_TO_SEAL,
        SEALED
    }

    enum Branch {
        LEFT,
        RIGHT
    }

    enum Side {
        ONE,
        TWO
    }

    /// @dev The unresolved representation shared by bisection and the final
    /// reveal at height one.
    struct BisectionView {
        Tree.Node revealingParent;
        Tree.Node waitingLeft;
        Tree.Node waitingRight;
        uint256 segmentStart;
        uint64 height;
    }

    struct SealedView {
        Machine.Hash agreeState;
        uint256 divergencePosition;
        Machine.Hash finalStateOne;
        Machine.Hash finalStateTwo;
    }

    struct Divergence {
        Tree.Node revealingLeaf;
        Tree.Node waitingLeaf;
        uint256 position;
    }

    // uint64 log2step; // constant
    // uint64 height; // constant

    function create(
        Commitment.Arguments memory args,
        Tree.Node one,
        Tree.Node two,
        Tree.Node leftNodeOfTwo,
        Tree.Node rightNodeOfTwo
    ) internal pure returns (IdHash, State memory) {
        assert(two.verify(leftNodeOfTwo, rightNodeOfTwo));

        Id memory matchId = Id({commitmentOne: one, commitmentTwo: two});

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

    function advanceBisection(
        State storage state,
        Tree.Node revealingLeft,
        Tree.Node revealingRight,
        Tree.Node nextLeft,
        Tree.Node nextRight
    ) internal {
        assert(state.currentHeight > 1);
        state.otherParent.requireChildren(revealingLeft, revealingRight);

        Branch branch = _selectBranch(state.leftNode, revealingLeft);
        Tree.Node revealingChild =
            branch == Branch.LEFT ? revealingLeft : revealingRight;
        revealingChild.requireChildren(nextLeft, nextRight);

        if (branch == Branch.LEFT) {
            state.otherParent = state.leftNode;
        } else {
            state.otherParent = state.rightNode;
            state.runningLeafPosition += uint256(1) << (state.currentHeight - 1);
        }
        state.leftNode = nextLeft;
        state.rightNode = nextRight;
        state.currentHeight--;
    }

    function sealDivergence(
        State storage state,
        Commitment.Arguments memory args,
        Id calldata id,
        Tree.Node revealingLeft,
        Tree.Node revealingRight,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    )
        internal
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        assert(state.currentHeight == 1);
        state.otherParent.requireChildren(revealingLeft, revealingRight);

        Branch branch = _selectBranch(state.leftNode, revealingLeft);
        Divergence memory divergence;
        divergence.revealingLeaf =
            branch == Branch.LEFT ? revealingLeft : revealingRight;
        divergence.waitingLeaf =
            branch == Branch.LEFT ? state.leftNode : state.rightNode;
        divergence.position = state.runningLeafPosition;
        if (branch == Branch.RIGHT) ++divergence.position;
        Side revealingSide = _sealingSide(args.height);

        _requireAgreeState(
            divergence, revealingSide, args, id, agreeState, agreeStateProof
        );
        (finalStateOne, finalStateTwo) =
            _fixedSideFinalStates(divergence, revealingSide);

        _encodeDivergence(state, divergence, branch);
        state._setAgreeState(agreeState);
    }

    //
    // View methods
    //
    /// @dev Supported tournament geometries have positive height. An initialized
    /// zero-height state is phase-indistinguishable from SEALED because both have
    /// `isInit == true` and `currentHeight == 0`.
    function phase(State memory state) internal pure returns (Phase) {
        if (!state.isInit) return Phase.UNINITIALIZED;
        if (state.currentHeight > 1) return Phase.BISECTING;
        if (state.currentHeight == 1) return Phase.READY_TO_SEAL;
        return Phase.SEALED;
    }

    function bisectionView(State memory state)
        internal
        pure
        returns (BisectionView memory view_)
    {
        state.requireExist();
        Phase currentPhase = state.phase();
        assert(
            currentPhase == Phase.BISECTING
                || currentPhase == Phase.READY_TO_SEAL
        );

        view_ = BisectionView({
            revealingParent: state.otherParent,
            waitingLeft: state.leftNode,
            waitingRight: state.rightNode,
            segmentStart: state.runningLeafPosition,
            height: state.currentHeight
        });
    }

    function sealedView(State memory state, uint64 totalHeight)
        internal
        pure
        returns (SealedView memory view_)
    {
        state.requireExist();
        state.requireIsSealed();

        Divergence memory divergence = _decodeDivergence(state);
        (Machine.Hash finalStateOne, Machine.Hash finalStateTwo) =
            _fixedSideFinalStates(divergence, _sealingSide(totalHeight));

        view_ = SealedView({
            agreeState: state.otherParent.toMachineHash(),
            divergencePosition: state.runningLeafPosition,
            finalStateOne: finalStateOne,
            finalStateTwo: finalStateTwo
        });
    }

    function exists(State memory state) internal pure returns (bool) {
        return state.isInit;
    }

    function isSealed(State memory state) internal pure returns (bool) {
        return state.currentHeight == 0;
    }

    function canBeSealed(State memory state) internal pure returns (bool) {
        return state.currentHeight == 1;
    }

    function canBeAdvanced(State memory state) internal pure returns (bool) {
        return state.currentHeight > 1;
    }

    function toCycle(State memory state, Commitment.Arguments memory args)
        internal
        pure
        returns (uint256)
    {
        return args.toCycle(state.runningLeafPosition);
    }

    function getDivergence(State memory state, Commitment.Arguments memory args)
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
        Divergence memory divergence = _decodeDivergence(state);
        agreeHash = state.otherParent.toMachineHash();
        agreeCycle = state.toCycle(args);
        (finalStateOne, finalStateTwo) =
            _fixedSideFinalStates(divergence, _sealingSide(args.height));
    }

    //
    // Requires
    //
    function requireExist(State memory state) internal pure {
        require(state.exists(), ITournament.MatchDoesNotExist());
    }

    function requireIsSealed(State memory state) internal pure {
        require(state.isSealed(), ITournament.MatchIsNotSealed());
    }

    function requireCanBeSealed(State memory state) internal pure {
        require(state.canBeSealed(), ITournament.MatchCannotBeSealed());
    }

    function requireCanBeAdvanced(State memory state) internal pure {
        require(state.canBeAdvanced(), ITournament.MatchCannotBeAdvanced());
    }

    //
    // Private
    //
    function _selectBranch(Tree.Node waitingLeft, Tree.Node revealingLeft)
        private
        pure
        returns (Branch)
    {
        // A left mismatch is necessarily the first divergent half.
        return revealingLeft.eq(waitingLeft) ? Branch.RIGHT : Branch.LEFT;
    }

    function _sealingSide(uint64 totalHeight) private pure returns (Side) {
        // Commitment one reveals first; H - 1 advances make it the final
        // revealer exactly when the total height is odd.
        return totalHeight % 2 == 1 ? Side.ONE : Side.TWO;
    }

    function _requireAgreeState(
        Divergence memory divergence,
        Side revealingSide,
        Commitment.Arguments memory args,
        Id calldata id,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    ) private pure {
        if (divergence.position == 0) {
            require(
                agreeState.eq(args.initialHash),
                ITournament.IncorrectAgreeState(args.initialHash, agreeState)
            );
            return;
        }

        Tree.Node commitment =
            revealingSide == Side.ONE ? id.commitmentOne : id.commitmentTwo;
        commitment.requireState(
            args.height, divergence.position - 1, agreeState, agreeStateProof
        );
    }

    function _fixedSideFinalStates(
        Divergence memory divergence,
        Side revealingSide
    )
        private
        pure
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        Machine.Hash revealingState = divergence.revealingLeaf.toMachineHash();
        Machine.Hash waitingState = divergence.waitingLeaf.toMachineHash();
        if (revealingSide == Side.ONE) {
            return (revealingState, waitingState);
        }
        return (waitingState, revealingState);
    }

    function _encodeDivergence(
        State storage state,
        Divergence memory divergence,
        Branch branch
    ) private {
        assert(state.currentHeight == 1);
        // Preserve the external branch-dependent encoding: left stores
        // waiting/revealing, while right stores revealing/waiting and an odd
        // position.
        if (branch == Branch.LEFT) {
            state.rightNode = divergence.revealingLeaf;
        } else {
            state.leftNode = divergence.revealingLeaf;
            state.runningLeafPosition = divergence.position;
        }
        state.currentHeight = 0;
    }

    function _decodeDivergence(State memory state)
        private
        pure
        returns (Divergence memory divergence)
    {
        // Interior right descents add even offsets. Only the final right seal
        // makes the position odd, so its low bit recovers the sealed branch.
        Branch branch =
            state.runningLeafPosition % 2 == 0 ? Branch.LEFT : Branch.RIGHT;
        divergence = Divergence({
            revealingLeaf: branch == Branch.LEFT
                ? state.rightNode
                : state.leftNode,
            waitingLeaf: branch == Branch.LEFT
                ? state.leftNode
                : state.rightNode,
            position: state.runningLeafPosition
        });
    }

    function _setAgreeState(State storage state, Machine.Hash agreeState)
        internal
    {
        assert(state.currentHeight == 0);
        state.otherParent = Tree.Node.wrap(Machine.Hash.unwrap(agreeState));
    }
}
