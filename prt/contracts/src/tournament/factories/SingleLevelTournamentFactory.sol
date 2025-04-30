// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/IStateTransition.sol";
import "prt-contracts/ITournamentFactory.sol";
import "prt-contracts/tournament/abstracts/Tournament.sol";
import "prt-contracts/tournament/concretes/SingleLevelTournament.sol";
import "prt-contracts/tournament/libs/Time.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    using Clones for address;

    uint64 constant START_CYCLE = 0;
    uint64 constant LEVEL = 0;
    uint64 constant LEVELS = 1;

    SingleLevelTournament immutable _impl;
    IStateTransition immutable _stateTransition;
    uint64 immutable _log2step;
    uint64 immutable _height;
    Time.Duration immutable _maxAllowance;
    Time.Duration immutable _matchEffort;

    constructor(
        SingleLevelTournament impl,
        IStateTransition stateTransition,
        uint64 log2step,
        uint64 height,
        Time.Duration maxAllowance,
        Time.Duration matchEffort
    ) {
        _impl = impl;
        _stateTransition = stateTransition;
        _log2step = log2step;
        _height = height;
        _maxAllowance = maxAllowance;
        _matchEffort = matchEffort;
    }

    function instantiateSingleLevel(
        Machine.Hash initialHash,
        IDataProvider provider
    ) public returns (SingleLevelTournament) {
        SingleLevelTournament.Args memory args = SingleLevelTournament.Args({
            tournamentArgs: TournamentArgs({
                initialHash: initialHash,
                startCycle: START_CYCLE,
                level: LEVEL,
                levels: LEVELS,
                log2step: _log2step,
                height: _height,
                startInstant: Time.currentTime(),
                allowance: _maxAllowance,
                maxAllowance: _maxAllowance,
                matchEffort: _matchEffort,
                provider: provider
            }),
            stateTransition: _stateTransition
        });
        address clone = address(_impl).cloneWithImmutableArgs(abi.encode(args));
        SingleLevelTournament tournament = SingleLevelTournament(clone);
        emit tournamentCreated(tournament);
        return tournament;
    }

    function instantiate(Machine.Hash initialHash, IDataProvider provider)
        external
        returns (ITournament)
    {
        return instantiateSingleLevel(initialHash, provider);
    }
}
