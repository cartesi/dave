// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {BaseDeploymentScript} from "prt-contracts/../script/BaseDeploymentScript.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";

contract DeploymentScript is BaseDeploymentScript {
    function run() external {
        _importDeployments("../../prt/contracts");
        _importDeployments("dependencies/cartesi-rollups-contracts-3.0.0-alpha.3");

        address inputBox = _loadDeployment(".", "InputBox");
        address appFactory = _loadDeployment(".", "ApplicationFactory");
        address tournamentFactory = _loadDeployment(".", "MultiLevelTournamentFactory");

        vmSafe.startBroadcast();

        _storeDeployment(
            type(DaveAppFactory).name,
            _create2(type(DaveAppFactory).creationCode, abi.encode(inputBox, appFactory, tournamentFactory))
        );

        vmSafe.stopBroadcast();
    }
}
