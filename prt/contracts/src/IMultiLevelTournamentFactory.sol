// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./ITournamentFactory.sol";

import "./tournament/concretes/TopTournament.sol";
import "./tournament/concretes/MiddleTournament.sol";
import "./tournament/concretes/BottomTournament.sol";

interface IMultiLevelTournamentFactory is ITournamentFactory {
    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        external
        returns (TopTournament);

    function instantiateMiddle(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level,
        IDataProvider _provider
    ) external returns (MiddleTournament);

    function instantiateBottom(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level,
        IDataProvider _provider
    ) external returns (BottomTournament);
}
