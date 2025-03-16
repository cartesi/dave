// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../concretes/BottomTournament.sol";

import "../../../TournamentParameters.sol";

contract BottomTournamentFactory {
    constructor() {}

    function instantiate(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level,
        TournamentParameters memory _tournamentParameters,
        IDataProvider _provider,
        IStateTransition _stateTransition
    ) external returns (BottomTournament) {
        BottomTournament _tournament = new BottomTournament(
            _initialHash,
            _contestedCommitmentOne,
            _contestedFinalStateOne,
            _contestedCommitmentTwo,
            _contestedFinalStateTwo,
            _allowance,
            _startCycle,
            _level,
            _tournamentParameters,
            _provider,
            _stateTransition
        );

        return _tournament;
    }
}
