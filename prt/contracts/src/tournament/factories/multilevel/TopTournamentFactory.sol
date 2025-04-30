// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/concretes/TopTournament.sol";
import "prt-contracts/types/TournamentParameters.sol";

contract TopTournamentFactory {
    using Clones for address;

    uint64 constant START_CYCLE = 0;
    uint64 constant LEVEL = 0;

    TopTournament immutable _impl;

    constructor(TopTournament impl) {
        _impl = impl;
    }

    function instantiate(
        Machine.Hash initialHash,
        TournamentParameters memory tournamentParameters,
        IDataProvider provider,
        IMultiLevelTournamentFactory tournamentFactory
    ) external returns (TopTournament) {
        TopTournament.Args memory args = TopTournament.Args({
            tournamentArgs: TournamentArgs({
                initialHash: initialHash,
                startCycle: START_CYCLE,
                level: LEVEL,
                levels: tournamentParameters.levels,
                log2step: tournamentParameters.log2step,
                height: tournamentParameters.height,
                startInstant: Time.currentTime(),
                allowance: tournamentParameters.maxAllowance,
                maxAllowance: tournamentParameters.maxAllowance,
                matchEffort: tournamentParameters.matchEffort,
                provider: provider
            }),
            tournamentFactory: tournamentFactory
        });
        address clone = address(_impl).cloneWithImmutableArgs(abi.encode(args));
        return TopTournament(clone);
    }
}
