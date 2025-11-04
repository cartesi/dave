// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {
    SingleLevelTournament
} from "prt-contracts/tournament/concretes/SingleLevelTournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    using Clones for address;

    uint64 constant START_CYCLE = 0;
    uint64 constant LEVEL = 0;
    uint64 constant LEVELS = 1;

    SingleLevelTournament immutable IMPL;
    IStateTransition immutable STATE_TRANSITION;
    uint64 immutable LOG2_STEP;
    uint64 immutable HEIGHT;
    Time.Duration immutable MAX_ALLOWANCE;
    Time.Duration immutable MATCH_EFFORT;

    constructor(
        SingleLevelTournament impl,
        IStateTransition stateTransition,
        uint64 log2step,
        uint64 height,
        Time.Duration maxAllowance,
        Time.Duration matchEffort
    ) {
        IMPL = impl;
        STATE_TRANSITION = stateTransition;
        LOG2_STEP = log2step;
        HEIGHT = height;
        MAX_ALLOWANCE = maxAllowance;
        MATCH_EFFORT = matchEffort;
    }

    function instantiateSingleLevel(
        Machine.Hash initialHash,
        IDataProvider provider
    ) public returns (SingleLevelTournament) {
        SingleLevelTournament.SingleLevelArguments memory
            args =
            SingleLevelTournament.SingleLevelArguments({
                tournamentArgs: ITournament.TournamentArguments({
                    commitmentArgs: Commitment.Arguments({
                        initialHash: initialHash,
                        startCycle: START_CYCLE,
                        log2step: LOG2_STEP,
                        height: HEIGHT
                    }),
                    level: LEVEL,
                    levels: LEVELS,
                    startInstant: Time.currentTime(),
                    allowance: MAX_ALLOWANCE,
                    maxAllowance: MAX_ALLOWANCE,
                    matchEffort: MATCH_EFFORT,
                    provider: provider
                }),
                stateTransition: STATE_TRANSITION
            });
        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        SingleLevelTournament tournament = SingleLevelTournament(clone);
        emit TournamentCreated(tournament);
        return tournament;
    }

    function instantiate(Machine.Hash initialHash, IDataProvider provider)
        external
        returns (ITournament)
    {
        return instantiateSingleLevel(initialHash, provider);
    }
}
