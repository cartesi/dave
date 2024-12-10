// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "src/Machine.sol";

import "src/tournament/factories/MultiLevelTournamentFactory.sol";
import "src/IDataProvider.sol";
import "src/CanonicalConstants.sol";

contract TopTournamentScript is Script {
    function run(Machine.Hash initialHash) external {
        uint64[] memory log2step = new uint64[](ArbitrationConstants.LEVELS);
        uint64[] memory height = new uint64[](ArbitrationConstants.LEVELS);

        for (uint64 i; i < ArbitrationConstants.LEVELS; ++i) {
            log2step[i] = ArbitrationConstants.log2step(i);
            height[i] = ArbitrationConstants.height(i);
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            ArbitrationConstants.MATCH_EFFORT,
            ArbitrationConstants.MAX_ALLOWANCE,
            log2step,
            height
        );

        factory.instantiate(initialHash, IDataProvider(address(0x0)));

        vm.stopBroadcast();
    }
}
