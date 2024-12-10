// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../abstracts/NonLeafTournament.sol";
import "../../concretes/MiddleTournament.sol";

import "../../../TournamentParameters.sol";
import "../../../IMultiLevelTournamentFactory.sol";

import "../../../Machine.sol";
import "../../../Tree.sol";
import "../../libs/Time.sol";

contract MiddleTournamentFactory {
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
        IMultiLevelTournamentFactory _tournamentFactory
    ) external returns (MiddleTournament) {
        MiddleTournament _tournament = new MiddleTournament(
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
            _tournamentFactory
        );

        return _tournament;
    }
}
