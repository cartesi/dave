// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {Machine} from "prt-contracts/Machine.sol";

import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/CanonicalConstants.sol";
import "rollups-contracts/inputs/InputBox.sol";
import "src/DaveConsensus.sol";

contract DaveConcensusScript is Script {
    function run(Machine.Hash initialHash) external {
        DisputeParameters memory disputeParameters = DisputeParameters({
            timeConstants: TimeConstants({
                matchEffort: ArbitrationConstants.MATCH_EFFORT,
                maxAllowance: ArbitrationConstants.MAX_ALLOWANCE
            }),
            commitmentStructures: new CommitmentStructure[](ArbitrationConstants.LEVELS)
        });

        for (uint64 i; i < ArbitrationConstants.LEVELS; ++i) {
            disputeParameters.commitmentStructures[i] = CommitmentStructure({
                log2step: ArbitrationConstants.log2step(i),
                height: ArbitrationConstants.height(i)
            });
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        InputBox inputBox = new InputBox();
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(), new MiddleTournamentFactory(), new BottomTournamentFactory(), disputeParameters
        );
        new DaveConsensus(inputBox, address(0x0), factory, initialHash);

        vm.stopBroadcast();
    }
}
