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

    function registerAndGetTiming() external returns (uint64, uint64) {
        _registerChains();
        _registerChainKinds();
        return (
            Time.Duration.unwrap(_getMatchEffort()),
            Time.Duration.unwrap(_getMaxAllowance())
        );
    }
}

contract DeploymentTest is Test {
    function testDevnetClockCalibration() public {
        DeploymentHarness harness = new DeploymentHarness();
        assertEq(harness.matchEffortInSeconds(), 5 minutes);

        vm.chainId(31337);
        (uint64 matchEffort, uint64 maxAllowance) =
            harness.registerAndGetTiming();
        assertEq(matchEffort, (5 minutes) / (12 seconds));
        assertEq(maxAllowance, (1 hours) / (12 seconds));
    }

    function testEthereumMainnetClockCalibration() public {
        DeploymentHarness harness = new DeploymentHarness();
        vm.chainId(1);

        (uint64 matchEffort, uint64 maxAllowance) =
            harness.registerAndGetTiming();
        assertEq(matchEffort, (5 minutes) / (12 seconds));
        assertEq(maxAllowance, (1 weeks + 1 hours) / (12 seconds));
    }

    function testEthereumSepoliaClockCalibration() public {
        DeploymentHarness harness = new DeploymentHarness();
        vm.chainId(11155111);

        (uint64 matchEffort, uint64 maxAllowance) =
            harness.registerAndGetTiming();
        assertEq(matchEffort, (5 minutes) / (12 seconds));
        assertEq(maxAllowance, (9 hours) / (12 seconds));
    }
}
