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

    using Time for Time.Instant;
    using Time for Time.Duration;

    /// @notice get the dangling commitment at current level and then retrieve the winner commitment
    /// @return (bool, Tree.Node, Tree.Node)
    /// - if the tournament is finished
    /// - the contested parent commitment
    /// - the dangling commitment
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

        NonRootTournamentArgs memory args = _nonRootTournamentArgs();
        if (_finalState.eq(args.contestedFinalStateOne)) {
            return (true, args.contestedCommitmentOne, _danglingCommitment);
        } else {
            assert(_finalState.eq(args.contestedFinalStateTwo));
            return (true, args.contestedCommitmentTwo, _danglingCommitment);
        }
    }
    /// @notice returns whether this inner tournament can be safely eliminated.
    /// @return (bool)
    /// - if the tournament can be eliminated

    function canBeEliminated() external view returns (bool) {
        if (!isFinished()) {
            return false;
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();

        // If the tournament is finished but has no winners,
        // inner tournament can be eliminated
        if (!_hasDanglingCommitment) {
            return true;
        }

        (Clock.State memory clock,) = getCommitment(_danglingCommitment);

        TournamentArgs memory args = _tournamentArgs();

        // Here, we know that `lastMatchElimination` holds the Instant when `matchCount` became zero.
        // We know that, after `lastMatchElimination` plus  winner's clock.allowance has elapsed,
        // it is safe to elminate the tournament.
        // However, we still must consider when the tournament was closed
        Time.Instant tournamentClosed = args.startInstant.add(args.allowance);
        Time.Instant winnerCouldWin = tournamentClosed.max(lastMatchElimination);

        // Otherwise, if winner allowance has elapsed since winner could have won,
        // inner tournament can be eliminated
        return winnerCouldWin.timeoutElapsed(clock.allowance);
    }

    /// @notice a final state is valid if it's equal to ContestedFinalStateOne or ContestedFinalStateTwo
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        override
        returns (bool, Machine.Hash, Machine.Hash)
    {
        NonRootTournamentArgs memory args = _nonRootTournamentArgs();
        return (
            args.contestedFinalStateOne.eq(_finalState)
                || args.contestedFinalStateTwo.eq(_finalState),
            args.contestedFinalStateOne,
            args.contestedFinalStateTwo
        );
    }

    function _nonRootTournamentArgs()
        internal
        view
        virtual
        returns (NonRootTournamentArgs memory);
}
