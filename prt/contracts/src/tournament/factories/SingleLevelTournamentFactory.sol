// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../concretes/SingleLevelTournament.sol";
import "../../ITournamentFactory.sol";
import "../../TournamentParameters.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    uint64 immutable log2step0;
    uint64 immutable height0;
    Time.Duration immutable matchEffort;
    Time.Duration immutable maxAllowance;
    IStateTransition immutable stateTransition;

    constructor(
        Time.Duration _matchEffort,
        Time.Duration _maxAllowance,
        uint64 _log2step,
        uint64 _height,
        IStateTransition _stateTransition
    ) {
        matchEffort = _matchEffort;
        maxAllowance = _maxAllowance;
        log2step0 = _log2step;
        height0 = _height;
        stateTransition = _stateTransition;
    }

    function instantiateSingleLevel(
        Machine.Hash _initialHash,
        IDataProvider _provider
    ) external returns (SingleLevelTournament) {
        SingleLevelTournament _tournament = new SingleLevelTournament(
            _initialHash, _getTournamentParameters(), _provider, stateTransition
        );

        emit tournamentCreated(_tournament);

        return _tournament;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider _provider)
        external
        returns (ITournament)
    {
        return this.instantiateSingleLevel(_initialHash, _provider);
    }

    function _getTournamentParameters()
        internal
        view
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: 1,
            log2step: log2step0,
            height: height0,
            matchEffort: matchEffort,
            maxAllowance: maxAllowance
        });
    }
}
