// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    NonRootTournament
} from "prt-contracts/tournament/abstracts/NonRootTournament.sol";
import {
    BottomTournament
} from "prt-contracts/tournament/concretes/BottomTournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract BottomTournamentFactory {
    using Clones for address;

    BottomTournament immutable IMPL;

    constructor(BottomTournament impl) {
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
        TournamentParameters calldata tournamentParameters,
        IDataProvider provider,
        IStateTransition stateTransition
    ) external returns (BottomTournament) {
        BottomTournament.BottomArguments memory
            args =
            BottomTournament.BottomArguments({
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
                nonRootTournamentArgs: NonRootTournament.NonRootArguments({
                    contestedCommitmentOne: contestedCommitmentOne,
                    contestedFinalStateOne: contestedFinalStateOne,
                    contestedCommitmentTwo: contestedCommitmentTwo,
                    contestedFinalStateTwo: contestedFinalStateTwo
                }),
                stateTransition: stateTransition
            });
        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        return BottomTournament(clone);
    }
}
