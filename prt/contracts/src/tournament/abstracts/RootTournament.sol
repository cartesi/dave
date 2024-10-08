// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./Tournament.sol";
import "../../ITournament.sol";

/// @notice Root tournament has no parent
abstract contract RootTournament is Tournament, ITournament {
    //
    // Constructor
    //
    constructor(Machine.Hash _initialHash)
        Tournament(_initialHash, ArbitrationConstants.MAX_ALLOWANCE, 0, 0)
    {}

    function validContestedFinalState(Machine.Hash)
        internal
        pure
        override
        returns (bool)
    {
        // always returns true in root tournament
        return true;
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
