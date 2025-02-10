// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../IMultiLevelTournamentFactory.sol";
import "../../TournamentParameters.sol";
import "../../ITournamentParametersProvider.sol";

import "./multilevel/TopTournamentFactory.sol";
import "./multilevel/MiddleTournamentFactory.sol";
import "./multilevel/BottomTournamentFactory.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;
    ITournamentParametersProvider immutable tournamentParametersProvider;

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory,
        ITournamentParametersProvider _tournamentParametersProvider
    ) {
        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;
        tournamentParametersProvider = _tournamentParametersProvider;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider _provider)
        external
        override
        returns (ITournament)
    {
        TopTournament _tournament = instantiateTop(_initialHash, _provider);
        emit tournamentCreated(_tournament);
        return _tournament;
    }

    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        public
        override
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
    ) external override returns (MiddleTournament) {
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
    ) external override returns (BottomTournament) {
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
        return _getTournamentParameters(0);
    }

    function _getTournamentParameters(uint64 _level)
        internal
        view
        returns (TournamentParameters memory)
    {
        return tournamentParametersProvider.tournamentParameters(_level);
    }
}
