// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../ITournamentFactory.sol";

import "../concretes/TopTournament.sol";
import "../concretes/MiddleTournament.sol";
import "../concretes/BottomTournament.sol";

import "./multilevel/TopTournamentFactory.sol";
import "./multilevel/MiddleTournamentFactory.sol";
import "./multilevel/BottomTournamentFactory.sol";

contract MultiLevelTournamentFactory is ITournamentFactory {
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

    function instantiate(Machine.Hash _initialHash, IDataProvider provider)
        external
        override
        returns (ITournament)
    {
        TopTournament _tournament = this.instantiateTop(_initialHash);
        emit tournamentCreated(_tournament);
        return _tournament;
    }

    function instantiateTop(Machine.Hash _initialHash)
        external
        returns (TopTournament)
    {
        TopTournament _tournament = topFactory.instantiate(_initialHash);
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
    ) external returns (MiddleTournament) {
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
    ) external returns (BottomTournament) {
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
