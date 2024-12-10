// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../IMultiLevelTournamentFactory.sol";
import "../../TournamentParameters.sol";

import "./multilevel/TopTournamentFactory.sol";
import "./multilevel/MiddleTournamentFactory.sol";
import "./multilevel/BottomTournamentFactory.sol";

struct CommitmentStructure {
    uint64 log2step;
    uint64 height;
}

struct TimeConstants {
    Time.Duration matchEffort;
    Time.Duration maxAllowance;
}

struct DisputeParameters {
    TimeConstants timeConstants;
    CommitmentStructure[] commitmentStructures;
}

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;
    uint64 immutable levels;
    Time.Duration immutable matchEffort;
    Time.Duration immutable maxAllowance;
    uint64 immutable log2step0;
    uint64 immutable height0;
    CommitmentStructure[] commitmentStructures;

    error CommitmentStructuresArrayLengthTooSmall();
    error CommitmentStructuresArrayLengthTooLarge();

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory,
        DisputeParameters memory _disputeParameters
    ) {
        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;

        require(
            _disputeParameters.commitmentStructures.length >= 1,
            CommitmentStructuresArrayLengthTooSmall()
        );
        require(
            _disputeParameters.commitmentStructures.length <= type(uint64).max,
            CommitmentStructuresArrayLengthTooLarge()
        );

        levels = uint64(_disputeParameters.commitmentStructures.length);
        matchEffort = _disputeParameters.timeConstants.matchEffort;
        maxAllowance = _disputeParameters.timeConstants.maxAllowance;
        log2step0 = _disputeParameters.commitmentStructures[0].log2step;
        height0 = _disputeParameters.commitmentStructures[0].height;
        commitmentStructures = _disputeParameters.commitmentStructures;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider _provider)
        external
        override
        returns (ITournament)
    {
        TopTournament _tournament = this.instantiateTop(_initialHash, _provider);
        emit tournamentCreated(_tournament);
        return _tournament;
    }

    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        external
        returns (TopTournament)
    {
        TopTournament _tournament = topFactory.instantiate(
            _initialHash, _getTopTournamentParameters(), _provider, this
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
        uint64 _level,
        IDataProvider _provider
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
            _getTournamentParameters(_level),
            _provider,
            this
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
        uint64 _level,
        IDataProvider _provider
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
            _getTournamentParameters(_level),
            _provider
        );

        return _tournament;
    }

    function _getTopTournamentParameters()
        internal
        view
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: levels,
            log2step: log2step0,
            height: height0,
            matchEffort: matchEffort,
            maxAllowance: maxAllowance
        });
    }

    function _getTournamentParameters(uint64 _level)
        internal
        view
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: levels,
            log2step: commitmentStructures[_level].log2step,
            height: commitmentStructures[_level].height,
            matchEffort: matchEffort,
            maxAllowance: maxAllowance
        });
    }
}
