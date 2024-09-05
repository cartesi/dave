// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./Tournament.sol";
import "./NonLeafTournament.sol";

/// @notice Non-root tournament needs to propagate side-effects to its parent
abstract contract NonRootTournament is Tournament {
    using Machine for Machine.Hash;
    using Tree for Tree.Node;

    //
    // Constants
    //
    Tree.Node immutable contestedCommitmentOne;
    Machine.Hash immutable contestedFinalStateOne;
    Tree.Node immutable contestedCommitmentTwo;
    Machine.Hash immutable contestedFinalStateTwo;

    //
    // Constructor
    //
    constructor(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) Tournament(_initialHash, _allowance, _startCycle, _level) {
        contestedCommitmentOne = _contestedCommitmentOne;
        contestedFinalStateOne = _contestedFinalStateOne;
        contestedCommitmentTwo = _contestedCommitmentTwo;
        contestedFinalStateTwo = _contestedFinalStateTwo;
    }

    /// @notice get the dangling commitment at current level and then retrieve the winner commitment
    /// @return (bool, Tree.Node, Tree.Node)
    /// - if the tournament is finished
    /// - the contested parent commitment
    /// - the dangling commitment
    // TODO: handle when no one wins, i.e no one joins the tournament
    function innerTournamentWinner()
        external
        view
        returns (bool, Tree.Node, Tree.Node)
    {
        if (!isFinished()) {
            return (false, Tree.ZERO_NODE, Tree.ZERO_NODE);
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();
        assert(_hasDanglingCommitment);

        Machine.Hash _finalState = finalStates[_danglingCommitment];

        if (_finalState.eq(contestedFinalStateOne)) {
            return (true, contestedCommitmentOne, _danglingCommitment);
        } else {
            assert(_finalState.eq(contestedFinalStateTwo));
            return (true, contestedCommitmentTwo, _danglingCommitment);
        }
    }

    /// @notice a final state is valid if it's equal to ContestedFinalStateOne or ContestedFinalStateTwo
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        override
        returns (bool)
    {
        return contestedFinalStateOne.eq(_finalState)
            || contestedFinalStateTwo.eq(_finalState);
    }
}
