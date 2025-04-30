// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import "prt-contracts/tournament/concretes/MiddleTournament.sol";
import "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";
import "prt-contracts/tournament/libs/Time.sol";
import "prt-contracts/types/Machine.sol";
import "prt-contracts/types/TournamentParameters.sol";
import "prt-contracts/types/Tree.sol";

contract MiddleTournamentFactory {
    using Clones for address;

    MiddleTournament immutable _impl;

    constructor(MiddleTournament impl) {
        _impl = impl;
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
        MiddleTournament.Args memory args = MiddleTournament.Args({
            tournamentArgs: TournamentArgs({
                initialHash: initialHash,
                startCycle: startCycle,
                level: level,
                levels: tournamentParameters.levels,
                log2step: tournamentParameters.log2step,
                height: tournamentParameters.height,
                startInstant: Time.currentTime(),
                allowance: allowance,
                maxAllowance: tournamentParameters.maxAllowance,
                matchEffort: tournamentParameters.matchEffort,
                provider: provider
            }),
            nonRootTournamentArgs: NonRootTournamentArgs({
                contestedCommitmentOne: contestedCommitmentOne,
                contestedFinalStateOne: contestedFinalStateOne,
                contestedCommitmentTwo: contestedCommitmentTwo,
                contestedFinalStateTwo: contestedFinalStateTwo
            }),
            tournamentFactory: tournamentFactory
        });
        address clone = address(_impl).cloneWithImmutableArgs(abi.encode(args));
        return MiddleTournament(clone);
    }
}
