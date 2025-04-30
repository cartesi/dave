// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std-1.9.6/src/Script.sol";

import {Machine} from "src/types/Machine.sol";

import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import
    "prt-contracts/arbitration-config/CanonicalTournamentParametersProvider.sol";
import "prt-contracts/IDataProvider.sol";
import "prt-contracts/state-transition/CmioStateTransition.sol";
import "prt-contracts/state-transition/RiscVStateTransition.sol";
import "prt-contracts/state-transition/CartesiStateTransition.sol";

contract TopTournamentScript is Script {
    function run(Machine.Hash initialHash) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(new TopTournament()),
            new MiddleTournamentFactory(new MiddleTournament()),
            new BottomTournamentFactory(new BottomTournament()),
            new CanonicalTournamentParametersProvider(),
            new CartesiStateTransition(
                new RiscVStateTransition(), new CmioStateTransition()
            )
        );

        factory.instantiate(initialHash, IDataProvider(address(0x0)));

        vm.stopBroadcast();
    }
}
