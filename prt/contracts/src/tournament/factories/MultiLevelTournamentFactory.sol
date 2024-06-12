// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./IMultiLevelTournamentFactory.sol";
import "./TopTournamentFactory.sol";
import "./MiddleTournamentFactory.sol";
import "./BottomTournamentFactory.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory
    ) {
        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;
    }

    function instantiateRoot(Machine.Hash _initialHash)
        external
        override
        returns (RootTournament)
    {
        RootTournament _tournament = topFactory.instantiate(_initialHash);
        emit rootCreated(_tournament);

        return _tournament;
    }

    function instantiateMiddle(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) external override returns (Tournament) {
        MiddleTournament _tournament = middleFactory.instantiate(
            _initialHash,
            _contestedCommitmentOne,
            _contestedFinalStateOne,
            _contestedCommitmentTwo,
            _contestedFinalStateTwo,
            _allowance,
            _startCycle,
            _level,
            NonLeafTournament(msg.sender)
        );

        return _tournament;
    }

    function instantiateBottom(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) external override returns (Tournament) {
        BottomTournament _tournament = bottomFactory.instantiate(
            _initialHash,
            _contestedCommitmentOne,
            _contestedFinalStateOne,
            _contestedCommitmentTwo,
            _contestedFinalStateTwo,
            _allowance,
            _startCycle,
            _level,
            NonLeafTournament(msg.sender)
        );

        return _tournament;
    }
}
