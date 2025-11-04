// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IMultiLevelTournamentFactory} from "./IMultiLevelTournamentFactory.sol";
import {
    BottomTournamentFactory
} from "./multilevel/BottomTournamentFactory.sol";
import {
    MiddleTournamentFactory
} from "./multilevel/MiddleTournamentFactory.sol";
import {TopTournamentFactory} from "./multilevel/TopTournamentFactory.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    ITournamentParametersProvider
} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    TopTournamentFactory immutable topFactory;
    MiddleTournamentFactory immutable middleFactory;
    BottomTournamentFactory immutable bottomFactory;
    ITournamentParametersProvider immutable tournamentParametersProvider;
    IStateTransition immutable stateTransition;

    constructor(
        TopTournamentFactory _topFactory,
        MiddleTournamentFactory _middleFactory,
        BottomTournamentFactory _bottomFactory,
        ITournamentParametersProvider _tournamentParametersProvider,
        IStateTransition _stateTransition
    ) {
        topFactory = _topFactory;
        middleFactory = _middleFactory;
        bottomFactory = _bottomFactory;
        tournamentParametersProvider = _tournamentParametersProvider;
        stateTransition = _stateTransition;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider _provider)
        external
        override
        returns (ITournament)
    {
        ITournament _tournament = instantiateTop(_initialHash, _provider);
        emit TournamentCreated(_tournament);
        return _tournament;
    }

    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        public
        override
        returns (ITournament)
    {
        return topFactory.instantiate(
            _initialHash, _getTopTournamentParameters(), _provider, this
        );
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
    ) external override returns (ITournament) {
        return middleFactory.instantiate(
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
    ) external override returns (ITournament) {
        return bottomFactory.instantiate(
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
            stateTransition
        );
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
