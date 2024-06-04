// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "src/tournament/abstracts/NonLeafTournament.sol";
import "src/tournament/concretes/MiddleTournament.sol";

import "src/tournament/factories/MultiLevelTournamentFactory.sol";

import "src/Machine.sol";
import "src/Tree.sol";
import "src/tournament/libs/Time.sol";

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
        NonLeafTournament _parent
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
            _parent,
            MultiLevelTournamentFactory(msg.sender)
        );

        return _tournament;
    }
}
