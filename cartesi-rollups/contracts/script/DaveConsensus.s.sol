// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "prt-contracts/Machine.sol";

import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "rollups-contracts/inputs/InputBox.sol";
import "src/DaveConsensus.sol";

contract DaveConcensusScript is Script {
    function run(Machine.Hash initialHash) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        InputBox inputBox = new InputBox();
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(), new MiddleTournamentFactory(), new BottomTournamentFactory()
        );
        new DaveConsensus(inputBox, address(0x0), factory, initialHash);

        vm.stopBroadcast();
    }
}
