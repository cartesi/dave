// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./Tournament.sol";
import "../../ITournament.sol";
import "../../TournamentParameters.sol";

/// @notice Root tournament has no parent
abstract contract RootTournament is Tournament, ITournament {
    //
    // Constructor
    //
    constructor(
        Machine.Hash _initialHash,
        TournamentParameters memory _tournamentParameters,
        IDataProvider _provider
    )
        Tournament(
            _initialHash,
            _tournamentParameters.maxAllowance,
            0,
            0,
            _tournamentParameters,
            _provider
        )
    {}

    function validContestedFinalState(Machine.Hash)
        internal
        pure
        override
        returns (bool, Machine.Hash, Machine.Hash)
    {
        // always returns true in root tournament
        return (true, Machine.ZERO_STATE, Machine.ZERO_STATE);
    }

    function arbitrationResult()
        external
        view
        override
        returns (bool, Tree.Node, Machine.Hash)
    {
        if (!isFinished()) {
            return (false, Tree.ZERO_NODE, Machine.ZERO_STATE);
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();
        assert(_hasDanglingCommitment);

        Machine.Hash _finalState = finalStates[_danglingCommitment];
        return (true, _danglingCommitment, _finalState);
    }
}
