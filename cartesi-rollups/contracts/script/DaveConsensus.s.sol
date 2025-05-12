// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std-1.9.6/src/Script.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/state-transition/CmioStateTransition.sol";
import "prt-contracts/state-transition/RiscVStateTransition.sol";
import "prt-contracts/state-transition/CartesiStateTransition.sol";
import "prt-contracts/../test/constants/TestTournamentParametersProvider.sol";

import "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";

import "src/DaveConsensus.sol";
import "src/DaveConsensusFactory.sol";

// Only used for tests
contract DaveConsensusScript is Script {
    function run(Machine.Hash initialHash, IInputBox inputBox) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MultiLevelTournamentFactory tournamentFactory = new MultiLevelTournamentFactory(
            new TopTournamentFactory(new TopTournament()),
            new MiddleTournamentFactory(new MiddleTournament()),
            new BottomTournamentFactory(new BottomTournament()),
            new TestTournamentParametersProvider(),
            new CartesiStateTransition(new RiscVStateTransition(), new CmioStateTransition())
        );

        DaveConsensusFactory daveConsensusFactory =
            new DaveConsensusFactory(new DaveConsensus(), inputBox, tournamentFactory);

        daveConsensusFactory.newDaveConsensus(address(0), initialHash);

        vm.stopBroadcast();
    }
}
