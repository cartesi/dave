// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./ITournament.sol";
import "./tournament/abstracts/Tournament.sol";
import "./IDataProvider.sol";

interface ITournamentFactory {
    event tournamentCreated(Tournament);

    function instantiate(Machine.Hash initialState, IDataProvider provider)
        external
        returns (ITournament);
}
