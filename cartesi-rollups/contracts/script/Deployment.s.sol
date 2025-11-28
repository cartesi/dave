// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {BaseDeploymentScript} from "prt-contracts/../script/BaseDeploymentScript.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {TestErc20} from "src/TestErc20.sol";

contract DeploymentScript is BaseDeploymentScript {
    string constant PRT_CONTRACTS = "../../prt/contracts";
    string constant ROLLUPS_CONTRACTS = "dependencies/cartesi-rollups-contracts-8ca7442d";

    function run() external {
        address inputBox = _loadDeployment(ROLLUPS_CONTRACTS, "InputBox");
        address appFactory = _loadDeployment(ROLLUPS_CONTRACTS, "ApplicationFactory");
        address tournamentFactory = _loadDeployment(PRT_CONTRACTS, "MultiLevelTournamentFactory");

        vmSafe.startBroadcast();

        _storeDeployment(
            type(DaveAppFactory).name,
            _create2(type(DaveAppFactory).creationCode, abi.encode(inputBox, appFactory, tournamentFactory))
        );

        if (block.chainid == 31337) {
            _storeDeployment(type(TestErc20).name, _create2(type(TestErc20).creationCode, abi.encode()));
        }

        vmSafe.stopBroadcast();
    }
}
