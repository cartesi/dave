// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "src/Machine.sol";

import "src/tournament/factories/TournamentFactory.sol";

contract TopTournamentScript is Script {
    function run(Machine.Hash initialHash) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        TournamentFactory factory = new TournamentFactory(
            new SingleLevelTournamentFactory(),
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory()
        );

        factory.instantiateTop(initialHash);

        vm.stopBroadcast();
    }
}
