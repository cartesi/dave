// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IMultiLevelTournamentFactory} from "./IMultiLevelTournamentFactory.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Tournament} from "prt-contracts/tournament/concretes/Tournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    using Clones for address;

    uint64 constant START_CYCLE = 0;
    uint64 constant LEVEL = 0;
    uint64 constant LEVELS = 1;

    Tournament immutable IMPL;
    IStateTransition immutable STATE_TRANSITION;
    uint64 immutable LOG2_STEP;
    uint64 immutable HEIGHT;
    Time.Duration immutable MAX_ALLOWANCE;
    Time.Duration immutable MATCH_EFFORT;

    constructor(
        Tournament impl,
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
    ) public returns (ITournament) {
        Tournament.CloneArguments memory args =
            Tournament.CloneArguments({
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
                nonRootTournamentArgs: ITournament.NonRootArguments({
                    contestedCommitmentOne: Tree.ZERO_NODE,
                    contestedFinalStateOne: Machine.ZERO_STATE,
                    contestedCommitmentTwo: Tree.ZERO_NODE,
                    contestedFinalStateTwo: Machine.ZERO_STATE
                }),
                stateTransition: STATE_TRANSITION,
                tournamentFactory: IMultiLevelTournamentFactory(address(0))
            });

        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        ITournament tournament = ITournament(clone);
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
