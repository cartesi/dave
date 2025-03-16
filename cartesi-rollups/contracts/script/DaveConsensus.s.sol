// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "prt-contracts/Machine.sol";

import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/CanonicalTournamentParametersProvider.sol";
import "prt-contracts/CmioStateTransition.sol";
import "prt-contracts/RiscVStateTransition.sol";
import "prt-contracts/StateTransition.sol";
import "rollups-contracts/inputs/IInputBox.sol";
import "src/DaveConsensus.sol";

contract DaveConsensusScript is Script {
    function run(Machine.Hash initialHash, IInputBox inputBox) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            new CanonicalTournamentParametersProvider(),
            new StateTransition(new RiscVStateTransition(), new CmioStateTransition())
        );

        new DaveConsensus(inputBox, address(0x0), factory, initialHash);

        vm.stopBroadcast();
    }
}
