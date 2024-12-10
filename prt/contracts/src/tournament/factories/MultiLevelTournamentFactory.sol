// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../IMultiLevelTournamentFactory.sol";

import "./multilevel/TopTournamentFactory.sol";
import "./multilevel/MiddleTournamentFactory.sol";
import "./multilevel/BottomTournamentFactory.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;
    Time.Duration immutable matchEffort;
    Time.Duration immutable maxAllowance;
    uint64 immutable levels;
    uint64[] log2step;
    uint64[] height;

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory,
        Time.Duration _matchEffort,
        Time.Duration _maxAllowance,
        uint64 _levels,
        uint64[] memory _log2step,
        uint64[] memory _height
    ) {
        require(_levels > 0, "levels cannot be zero");
        require(_log2step.length == _levels, "bad log2step array length");
        require(_height.length == _levels, "bad height array length");

        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;
        matchEffort = _matchEffort;
        maxAllowance = _maxAllowance;
        levels = _levels;
        log2step = _log2step;
        height = _height;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider)
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
        TopTournament _tournament = topFactory.instantiate(
            _initialHash,
            matchEffort,
            maxAllowance,
            levels,
            log2step[0],
            height[0]
        );
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
            matchEffort,
            maxAllowance,
            _startCycle,
            _level,
            levels,
            log2step[_level],
            height[_level]
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
            matchEffort,
            maxAllowance,
            _startCycle,
            _level,
            levels,
            log2step[_level],
            height[_level]
        );

        return _tournament;
    }
}
