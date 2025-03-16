// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "src/Machine.sol";

import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/CanonicalTournamentParametersProvider.sol";
import "src/IDataProvider.sol";
import "src/CmioStateTransition.sol";
import "src/RiscVStateTransition.sol";
import "src/StateTransition.sol";

contract TopTournamentScript is Script {
    function run(Machine.Hash initialHash) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            new CanonicalTournamentParametersProvider(),
            new StateTransition(
                new RiscVStateTransition(), new CmioStateTransition()
            )
        );

        factory.instantiate(initialHash, IDataProvider(address(0x0)));

        vm.stopBroadcast();
    }
}
