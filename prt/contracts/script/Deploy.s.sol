// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "src/Machine.sol";

import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/IDataProvider.sol";
import "src/CanonicalConstants.sol";

contract DeployScript is Script {
    modifier broadcast() {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    function deployTopTournament(Machine.Hash initialHash) external broadcast {
        MultiLevelTournamentFactory factory = _deployFactory();
        factory.instantiate(initialHash, IDataProvider(address(0x0)));
    }

    function _deployFactory() internal returns (MultiLevelTournamentFactory) {
        return new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            ArbitrationConstants.disputeParameters()
        );
    }
}
