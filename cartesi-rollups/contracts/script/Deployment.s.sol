// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {BaseDeploymentScript} from "prt-contracts/../script/BaseDeploymentScript.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {TestFungibleToken} from "src/TestFungibleToken.sol";
import {TestMultiToken} from "src/TestMultiToken.sol";
import {TestNonFungibleToken} from "src/TestNonFungibleToken.sol";

contract DeploymentScript is BaseDeploymentScript {
    function run() external {
        _importDeployments("../../prt/contracts");
        _importDeployments("dependencies/cartesi-rollups-contracts-2.2.0");

        address inputBox = _loadDeployment(".", "InputBox");
        address appFactory = _loadDeployment(".", "ApplicationFactory");
        address tournamentFactory = _loadDeployment(".", "MultiLevelTournamentFactory");

        vmSafe.startBroadcast();

        _storeDeployment(
            type(DaveAppFactory).name,
            _create2(type(DaveAppFactory).creationCode, abi.encode(inputBox, appFactory, tournamentFactory))
        );

        if (block.chainid == 31337) {
            /// forgefmt: disable-start
            _storeDeployment(type(TestFungibleToken).name, _create2(type(TestFungibleToken).creationCode, abi.encode()));
            _storeDeployment(type(TestNonFungibleToken).name, _create2(type(TestNonFungibleToken).creationCode, abi.encode()));
            _storeDeployment(type(TestMultiToken).name, _create2(type(TestMultiToken).creationCode, abi.encode()));
            /// forgefmt: disable-end
        }

        vmSafe.stopBroadcast();
    }
}
