// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/concretes/TopTournament.sol";

import "prt-contracts/types/TournamentParameters.sol";

contract TopTournamentFactory {
    constructor() {}

    function instantiate(
        Machine.Hash _initialHash,
        TournamentParameters memory _tournamentParameters,
        IDataProvider _provider,
        IMultiLevelTournamentFactory _tournamentFactory
    ) external returns (TopTournament) {
        TopTournament _tournament = new TopTournament(
            _initialHash, _tournamentParameters, _provider, _tournamentFactory
        );

        return _tournament;
    }
}
