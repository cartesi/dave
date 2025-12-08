// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    MiddleTournament
} from "prt-contracts/tournament/concretes/MiddleTournament.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract MiddleTournamentFactory {
    using Clones for address;

    MiddleTournament immutable IMPL;

    constructor(MiddleTournament impl) {
        IMPL = impl;
    }

    function instantiate(
        Machine.Hash initialHash,
        Tree.Node contestedCommitmentOne,
        Machine.Hash contestedFinalStateOne,
        Tree.Node contestedCommitmentTwo,
        Machine.Hash contestedFinalStateTwo,
        Time.Duration allowance,
        uint256 startCycle,
        uint64 level,
        TournamentParameters memory tournamentParameters,
        IDataProvider provider,
        IMultiLevelTournamentFactory tournamentFactory
    ) external returns (MiddleTournament) {
        MiddleTournament.MiddleArguments memory args =
            MiddleTournament.MiddleArguments({
                tournamentArgs: ITournament.TournamentArguments({
                    commitmentArgs: Commitment.Arguments({
                        initialHash: initialHash,
                        startCycle: startCycle,
                        log2step: tournamentParameters.log2step,
                        height: tournamentParameters.height
                    }),
                    level: level,
                    levels: tournamentParameters.levels,
                    startInstant: Time.currentTime(),
                    allowance: allowance,
                    maxAllowance: tournamentParameters.maxAllowance,
                    matchEffort: tournamentParameters.matchEffort,
                    provider: provider
                }),
                nonRootTournamentArgs: ITournament.NonRootArguments({
                    contestedCommitmentOne: contestedCommitmentOne,
                    contestedFinalStateOne: contestedFinalStateOne,
                    contestedCommitmentTwo: contestedCommitmentTwo,
                    contestedFinalStateTwo: contestedFinalStateTwo
                }),
                tournamentFactory: tournamentFactory
            });
        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        return MiddleTournament(clone);
    }
}
