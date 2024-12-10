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
        DisputeParameters memory disputeParameters = DisputeParameters({
            timeConstants: TimeConstants({
                matchEffort: ArbitrationConstants.MATCH_EFFORT,
                maxAllowance: ArbitrationConstants.MAX_ALLOWANCE
            }),
            commitmentStructures: new CommitmentStructure[](
                ArbitrationConstants.LEVELS
            )
        });

        for (uint64 i; i < ArbitrationConstants.LEVELS; ++i) {
            disputeParameters.commitmentStructures[i] = CommitmentStructure({
                log2step: ArbitrationConstants.log2step(i),
                height: ArbitrationConstants.height(i)
            });
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(),
            new MiddleTournamentFactory(),
            new BottomTournamentFactory(),
            disputeParameters
        );

        factory.instantiate(initialHash, IDataProvider(address(0x0)));

        vm.stopBroadcast();
    }
}
