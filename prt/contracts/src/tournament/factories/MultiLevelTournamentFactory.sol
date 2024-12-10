// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../IMultiLevelTournamentFactory.sol";
import "../../ITournamentParameters.sol";

import "./multilevel/TopTournamentFactory.sol";
import "./multilevel/MiddleTournamentFactory.sol";
import "./multilevel/BottomTournamentFactory.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory, ITournamentParameters {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;
    uint64 public immutable levels;
    Time.Duration public immutable matchEffort;
    Time.Duration public immutable maxAllowance;
    uint64[] public log2step;
    uint64[] public height;

    error ArrayLengthMismatch();
    error ArrayLengthTooLarge();

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory,
        Time.Duration _matchEffort,
        Time.Duration _maxAllowance,
        uint64[] memory _log2step,
        uint64[] memory _height
    ) {
        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;

        require(log2step.length == height.length, ArrayLengthMismatch());
        require(log2step.length <= type(uint64).max, ArrayLengthTooLarge());

        levels = uint64(_log2step.length);
        matchEffort = _matchEffort;
        maxAllowance = _maxAllowance;
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
            _level
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
            _level
        );

        return _tournament;
    }
}
