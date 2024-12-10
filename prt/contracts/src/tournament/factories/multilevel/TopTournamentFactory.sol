// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../concretes/TopTournament.sol";

import "../../../ITournamentParameters.sol";

contract TopTournamentFactory {
    constructor() {}

    function instantiate(
        ITournamentParameters _tournamentParameters,
        Machine.Hash _initialHash
    ) external returns (TopTournament) {
        TopTournament _tournament = new TopTournament(
            _tournamentParameters,
            _initialHash,
            IMultiLevelTournamentFactory(msg.sender)
        );

        return _tournament;
    }
}
