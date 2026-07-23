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
/// readers should establish the derived phase and use `SealedView` for sealed
/// state instead of interpreting its overloaded slots directly.
library Match {
    using Tree for Tree.Node;
    using Match for Id;
    using Match for State;
    using Machine for Machine.Hash;
    using Commitment for Tree.Node;

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

    enum CommitmentSide {
        ONE,
        TWO
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

    function create(
        uint64 height,
        Tree.Node one,
        Tree.Node two,
        Tree.Node leftNodeOfTwo,
        Tree.Node rightNodeOfTwo
    ) internal pure returns (IdHash, State memory) {
        // A zero-height state would be born phase-indistinguishable from
        // SEALED; supported geometries are validated to positive height.
        assert(height > 0);
        assert(two.verify(leftNodeOfTwo, rightNodeOfTwo));

        Id memory matchId = Id({commitmentOne: one, commitmentTwo: two});

        State memory state = State({
            otherParent: one,
            leftNode: leftNodeOfTwo,
            rightNode: rightNodeOfTwo,
            runningLeafPosition: 0,
            currentHeight: height,
            isInit: true
        });

        return (matchId.hashFromId(), state);
    }

    /// @notice Advance the shared divergence frontier by one tree level.
    /// @dev The waiting commitment's children are already cached. The current
    /// revealer opens its parent to select the first divergent branch, then
    /// opens its selected child into `nextLeft` and `nextRight`. The selected
    /// child from each commitment becomes the next frontier and the roles swap.
    /// Each commitment therefore supplies two adjacent openings on alternating
    /// turns, while the two-tree search descends one level per call.
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
        if (branch == Branch.LEFT) {
            revealingLeft.requireChildren(nextLeft, nextRight);
            state.otherParent = state.leftNode;
        } else {
            revealingRight.requireChildren(nextLeft, nextRight);
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
        if (branch == Branch.LEFT) {
            divergence = Divergence({
                revealingLeaf: revealingLeft,
                waitingLeaf: state.leftNode,
                position: state.runningLeafPosition
            });
        } else {
            divergence = Divergence({
                revealingLeaf: revealingRight,
                waitingLeaf: state.rightNode,
                position: state.runningLeafPosition + 1
            });
        }
        CommitmentSide revealingSide = _finalRevealingSide(args.height);

        _requireAgreeState(
            divergence, revealingSide, args, id, agreeState, agreeStateProof
        );
        (finalStateOne, finalStateTwo) =
            _finalStatesByCommitment(divergence, revealingSide);

        _storeSealedDivergence(state, divergence, branch, agreeState);
    }

    //
    // View methods
    //
    /// @dev Supported tournament geometries have positive height. An initialized
    /// zero-height state is phase-indistinguishable from SEALED because both have
    /// `isInit == true` and `currentHeight == 0`.
    function phase(State memory state) internal pure returns (Phase) {
        return _phase(state.isInit, state.currentHeight);
    }

    function sealedView(State memory state, uint64 totalHeight)
        internal
        pure
        returns (SealedView memory view_)
    {
        Phase currentPhase = state.phase();
        require(
            currentPhase != Phase.UNINITIALIZED, ITournament.MatchDoesNotExist()
        );
        require(currentPhase == Phase.SEALED, ITournament.MatchIsNotSealed());

        Divergence memory divergence = _decodeDivergence(state);
        (Machine.Hash finalStateOne, Machine.Hash finalStateTwo) = _finalStatesByCommitment(
            divergence, _finalRevealingSide(totalHeight)
        );

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
        return state.phase() == Phase.SEALED;
    }

    function canBeSealed(State memory state) internal pure returns (bool) {
        return state.phase() == Phase.READY_TO_SEAL;
    }

    function canBeAdvanced(State memory state) internal pure returns (bool) {
        return state.phase() == Phase.BISECTING;
    }

    //
    // Requires
    //
    function requireExists(State storage state) internal view {
        require(state.isInit, ITournament.MatchDoesNotExist());
    }

    function requireSealed(State storage state) internal view {
        Phase currentPhase = _establishedPhase(state);
        require(currentPhase == Phase.SEALED, ITournament.MatchIsNotSealed());
    }

    function requireCanBeSealed(State storage state) internal view {
        Phase currentPhase = _establishedPhase(state);
        require(
            currentPhase == Phase.READY_TO_SEAL,
            ITournament.MatchCannotBeSealed()
        );
    }

    function requireCanBeAdvanced(State storage state) internal view {
        Phase currentPhase = _establishedPhase(state);
        require(
            currentPhase == Phase.BISECTING, ITournament.MatchCannotBeAdvanced()
        );
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

    function _finalRevealingSide(uint64 totalHeight)
        private
        pure
        returns (CommitmentSide)
    {
        // Commitment one reveals first; H - 1 advances make it the final
        // revealer exactly when the total height is odd.
        return totalHeight % 2 == 1 ? CommitmentSide.ONE : CommitmentSide.TWO;
    }

    function _requireAgreeState(
        Divergence memory divergence,
        CommitmentSide revealingSide,
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

        Tree.Node commitment = revealingSide == CommitmentSide.ONE
            ? id.commitmentOne
            : id.commitmentTwo;
        commitment.requireState(
            args.height, divergence.position - 1, agreeState, agreeStateProof
        );
    }

    function _finalStatesByCommitment(
        Divergence memory divergence,
        CommitmentSide revealingSide
    )
        private
        pure
        returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo)
    {
        Machine.Hash revealingState = divergence.revealingLeaf.toMachineHash();
        Machine.Hash waitingState = divergence.waitingLeaf.toMachineHash();
        if (revealingSide == CommitmentSide.ONE) {
            return (revealingState, waitingState);
        }
        return (waitingState, revealingState);
    }

    function _storeSealedDivergence(
        State storage state,
        Divergence memory divergence,
        Branch branch,
        Machine.Hash agreeState
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
        state.otherParent = Tree.Node.wrap(Machine.Hash.unwrap(agreeState));
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
        if (branch == Branch.LEFT) {
            divergence = Divergence({
                revealingLeaf: state.rightNode,
                waitingLeaf: state.leftNode,
                position: state.runningLeafPosition
            });
        } else {
            divergence = Divergence({
                revealingLeaf: state.leftNode,
                waitingLeaf: state.rightNode,
                position: state.runningLeafPosition
            });
        }
    }

    function _phase(bool isInit, uint64 currentHeight)
        private
        pure
        returns (Phase)
    {
        if (!isInit) {
            return Phase.UNINITIALIZED;
        } else if (currentHeight > 1) {
            return Phase.BISECTING;
        } else if (currentHeight == 1) {
            return Phase.READY_TO_SEAL;
        } else {
            return Phase.SEALED;
        }
    }

    /// @dev Establishes existence before any phase-specific error, reading
    /// only the packed phase slot. `sealedView` is the memory-domain twin of
    /// this precedence rule.
    function _establishedPhase(State storage state)
        private
        view
        returns (Phase currentPhase)
    {
        currentPhase = _phase(state.isInit, state.currentHeight);
        require(
            currentPhase != Phase.UNINITIALIZED, ITournament.MatchDoesNotExist()
        );
    }
}
