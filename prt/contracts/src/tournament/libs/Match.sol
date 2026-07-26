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
    /// waiting side's children. After sealing, `otherParent` stores the agree
    /// state while `leftNode` and `rightNode` store the final states of
    /// commitments one and two respectively.
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

    struct SealedView {
        Machine.Hash agreeState;
        uint256 divergencePosition;
        Machine.Hash finalStateOne;
        Machine.Hash finalStateTwo;
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

        // A left mismatch is necessarily the first divergent half.
        if (!revealingLeft.eq(state.leftNode)) {
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

        Tree.Node revealingFinalState;
        Tree.Node waitingFinalState;
        uint256 divergencePosition = state.runningLeafPosition;

        // A left mismatch is the first divergence. If the left nodes agree, the
        // commitments first diverge at the right leaf.
        if (!revealingLeft.eq(state.leftNode)) {
            revealingFinalState = revealingLeft;
            waitingFinalState = state.leftNode;
        } else {
            revealingFinalState = revealingRight;
            waitingFinalState = state.rightNode;
            divergencePosition++;
        }

        // Commitment one reveals first. After H - 1 advances it is also the
        // final revealer exactly when the total height is odd.
        Tree.Node revealingCommitment;
        Tree.Node finalStateOneNode;
        Tree.Node finalStateTwoNode;
        if (args.height % 2 == 1) {
            revealingCommitment = id.commitmentOne;
            finalStateOneNode = revealingFinalState;
            finalStateTwoNode = waitingFinalState;
        } else {
            revealingCommitment = id.commitmentTwo;
            finalStateOneNode = waitingFinalState;
            finalStateTwoNode = revealingFinalState;
        }

        _requireAgreeState(
            divergencePosition,
            revealingCommitment,
            args,
            agreeState,
            agreeStateProof
        );

        // Sealed states use canonical commitment order, independent of the
        // final revealing side or divergent branch.
        // `otherParent` is phase-overloaded here: preserve the machine-state
        // hash verbatim in its Tree.Node slot; no tree hash is performed.
        state.otherParent = Tree.Node.wrap(Machine.Hash.unwrap(agreeState));
        state.leftNode = finalStateOneNode;
        state.rightNode = finalStateTwoNode;
        state.runningLeafPosition = divergencePosition;
        state.currentHeight = 0;

        finalStateOne = finalStateOneNode.toMachineHash();
        finalStateTwo = finalStateTwoNode.toMachineHash();
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

    function sealedView(State memory state)
        internal
        pure
        returns (SealedView memory view_)
    {
        Phase currentPhase = state.phase();
        require(
            currentPhase != Phase.UNINITIALIZED, ITournament.MatchDoesNotExist()
        );
        require(currentPhase == Phase.SEALED, ITournament.MatchIsNotSealed());

        view_ = SealedView({
            agreeState: state.otherParent.toMachineHash(),
            divergencePosition: state.runningLeafPosition,
            finalStateOne: state.leftNode.toMachineHash(),
            finalStateTwo: state.rightNode.toMachineHash()
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
    function _requireAgreeState(
        uint256 divergencePosition,
        Tree.Node revealingCommitment,
        Commitment.Arguments memory args,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    ) private pure {
        if (divergencePosition == 0) {
            require(
                agreeState.eq(args.initialHash),
                ITournament.IncorrectAgreeState(args.initialHash, agreeState)
            );
            return;
        }

        revealingCommitment.requireState(
            args.height, divergencePosition - 1, agreeState, agreeStateProof
        );
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
