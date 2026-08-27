// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IERC165} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {ITournamentFactory} from "src/ITournamentFactory.sol";
import {IMultiLevelTournamentFactory} from "src/tournament/factories/IMultiLevelTournamentFactory.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Machine} from "src/types/Machine.sol";

import {Util} from "./Util.sol";

contract Erc165Test is Util {
    function testFactoryAdvertisesExactFactoryInterfaces() public {
        MultiLevelTournamentFactory factory =
            instantiateSingleLevelTournamentFactory(0, 3);

        assertTrue(
            factory.supportsInterface(
                type(IMultiLevelTournamentFactory).interfaceId
            )
        );
        assertTrue(
            factory.supportsInterface(type(ITournamentFactory).interfaceId)
        );
        assertTrue(factory.supportsInterface(type(IERC165).interfaceId));
        assertFalse(factory.supportsInterface(0xffffffff));
        assertFalse(factory.supportsInterface(type(ITournament).interfaceId));
    }

    function testTournamentCloneAdvertisesExactTournamentInterface() public {
        MultiLevelTournamentFactory factory =
            instantiateSingleLevelTournamentFactory(0, 3);
        ITournament tournament =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));

        IERC165 clone = IERC165(address(tournament));
        assertTrue(clone.supportsInterface(type(ITournament).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC165).interfaceId));
        assertFalse(clone.supportsInterface(0xffffffff));
        assertFalse(
            clone.supportsInterface(
                type(IMultiLevelTournamentFactory).interfaceId
            )
        );
    }
}
