// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {DeploymentScript, Seconds} from "../script/Deployment.s.sol";
import {Time} from "src/tournament/libs/Time.sol";

contract DeploymentHarness is DeploymentScript {
    function matchEffortInSeconds() external pure returns (uint64) {
        return Seconds.unwrap(_getMatchEffortInSeconds());
    }

    function registerAndGetMatchEffort() external returns (uint64) {
        _registerChains();
        return Time.Duration.unwrap(_getMatchEffort());
    }
}

contract DeploymentTest is Test {
    function testResponseBudgetCalibration() public {
        DeploymentHarness harness = new DeploymentHarness();
        assertEq(harness.matchEffortInSeconds(), 5 minutes);

        vm.chainId(31337);
        assertEq(harness.registerAndGetMatchEffort(), 25);
    }
}
