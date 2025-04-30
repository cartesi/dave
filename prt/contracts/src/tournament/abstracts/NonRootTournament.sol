// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/abstracts/Tournament.sol";
import "prt-contracts/types/TournamentParameters.sol";

struct NonRootTournamentArgs {
    Tree.Node contestedCommitmentOne;
    Machine.Hash contestedFinalStateOne;
    Tree.Node contestedCommitmentTwo;
    Machine.Hash contestedFinalStateTwo;
}

/// @notice Non-root tournament needs to propagate side-effects to its parent
abstract contract NonRootTournament is Tournament {
    using Machine for Machine.Hash;
    using Tree for Tree.Node;

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

        Machine.Hash contestedFinalStateOne;
        Tree.Node contestedCommitmentOne;
        Machine.Hash contestedFinalStateTwo;
        Tree.Node contestedCommitmentTwo;
        {
            NonRootTournamentArgs memory args;
            args = _nonRootTournamentArgs();
            contestedFinalStateOne = args.contestedFinalStateOne;
            contestedCommitmentOne = args.contestedCommitmentOne;
            contestedFinalStateTwo = args.contestedFinalStateTwo;
            contestedCommitmentTwo = args.contestedCommitmentTwo;
        }

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
        returns (bool, Machine.Hash, Machine.Hash)
    {
        Machine.Hash contestedFinalStateOne;
        Machine.Hash contestedFinalStateTwo;
        {
            NonRootTournamentArgs memory args;
            args = _nonRootTournamentArgs();
            contestedFinalStateOne = args.contestedFinalStateOne;
            contestedFinalStateTwo = args.contestedFinalStateTwo;
        }

        return (
            contestedFinalStateOne.eq(_finalState)
                || contestedFinalStateTwo.eq(_finalState),
            contestedFinalStateOne,
            contestedFinalStateTwo
        );
    }

    function _nonRootTournamentArgs()
        internal
        view
        virtual
        returns (NonRootTournamentArgs memory);
}
