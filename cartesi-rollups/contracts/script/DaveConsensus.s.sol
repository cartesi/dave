// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/state-transition/CmioStateTransition.sol";
import "prt-contracts/state-transition/RiscVStateTransition.sol";
import "prt-contracts/state-transition/CartesiStateTransition.sol";
import "prt-contracts/../test/constants/TestTournamentParametersProvider.sol";

import "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";

import "src/DaveConsensus.sol";

// Only used for tests
contract DaveConsensusScript is Script {
    function run(Machine.Hash initialHash, IInputBox inputBox) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            new TestTournamentParametersProvider(),
            new CartesiStateTransition(new RiscVStateTransition(), new CmioStateTransition())
        );

        new DaveConsensus(inputBox, address(0x0), factory, initialHash);

        vm.stopBroadcast();
    }
}
