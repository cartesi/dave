// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/ITournament.sol";
import "prt-contracts/tournament/abstracts/Tournament.sol";
import "prt-contracts/IDataProvider.sol";

interface ITournamentFactory {
    event tournamentCreated(ITournament);

    function instantiate(Machine.Hash initialState, IDataProvider provider)
        external
        returns (ITournament);
}
