// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

interface ITournamentFactory {
    event TournamentCreated(ITournament tournament);

    function instantiate(Machine.Hash initialState, IDataProvider provider)
        external
        returns (ITournament);
}
