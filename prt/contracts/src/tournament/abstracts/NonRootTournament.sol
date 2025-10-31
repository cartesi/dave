// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/abstracts/Tournament.sol";
import "prt-contracts/types/TournamentParameters.sol";

/// @notice Non-root tournament needs to propagate side-effects to its parent
abstract contract NonRootTournament is Tournament {
    using Machine for Machine.Hash;
    using Tree for Tree.Node;

    using Time for Time.Instant;
    using Time for Time.Duration;

    using Clock for Clock.State;

    struct NonRootArguments {
        Tree.Node contestedCommitmentOne;
        Machine.Hash contestedFinalStateOne;
        Tree.Node contestedCommitmentTwo;
        Machine.Hash contestedFinalStateTwo;
    }

    function innerTournamentWinner()
        external
        view
        returns (bool, Tree.Node, Tree.Node, Clock.State memory)
    {
        if (!isFinished() || canBeEliminated()) {
            Clock.State memory zeroClock;
            return (false, Tree.ZERO_NODE, Tree.ZERO_NODE, zeroClock);
        }

        (bool _hasDanglingCommitment, Tree.Node _winner) =
            hasDanglingCommitment();
        assert(_hasDanglingCommitment);

        (bool finished, Time.Instant timeFinished) = timeFinished();
        assert(finished);

        Clock.State memory _clock = clocks[_winner];
        _clock = _clock.deduct(Time.currentTime().timeSpan(timeFinished));

        NonRootArguments memory args = _nonRootTournamentArgs();
        Machine.Hash _finalState = finalStates[_winner];

        if (_finalState.eq(args.contestedFinalStateOne)) {
            return (true, args.contestedCommitmentOne, _winner, _clock);
        } else {
            assert(_finalState.eq(args.contestedFinalStateTwo));
            return (true, args.contestedCommitmentTwo, _winner, _clock);
        }
    }

    function canBeEliminated() public view returns (bool) {
        (bool finished, Time.Instant winnerCouldHaveWon) = timeFinished();

        if (!finished) {
            return false;
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();

        // If the tournament is finished but has no winners,
        // inner tournament can be eliminated
        if (!_hasDanglingCommitment) {
            return true;
        }

        // We know that, after `winnerCouldHaveWon` plus  winner's clock.allowance has elapsed,
        // it is safe to elminate the tournament.
        (Clock.State memory clock,) = getCommitment(_danglingCommitment);
        return winnerCouldHaveWon.timeoutElapsed(clock.allowance);
    }

    /// @notice a final state is valid if it's equal to ContestedFinalStateOne or ContestedFinalStateTwo
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        override
        returns (bool, Machine.Hash, Machine.Hash)
    {
        NonRootArguments memory args = _nonRootTournamentArgs();
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
        returns (NonRootArguments memory);
}
