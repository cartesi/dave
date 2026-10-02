// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {TableTournamentParametersProvider} from "../fixtures/TableTournamentParametersProvider.sol";
import {DevnetGeometryDeploymentScript} from "./DevnetGeometryDeployment.s.sol";

contract DevnetGeometryHarness is DevnetGeometryDeploymentScript {
    /// @notice Deploy the two-level provider exactly as `runTwoLevel` encodes it.
    function deployTwoLevelProvider()
        external
        returns (TableTournamentParametersProvider provider)
    {
        _registerChains();
        _registerChainKinds();
        bytes memory code = abi.encodePacked(
            type(TableTournamentParametersProvider).creationCode,
            _twoLevelProviderArguments()
        );
        assembly ("memory-safe") {
            provider := create(0, add(code, 32), mload(code))
        }
        require(address(provider) != address(0), "provider deployment failed");
    }
}

contract DevnetGeometryDeploymentTest is Test {
    function testTwoLevelProfileBudgets() public {
        DevnetGeometryHarness harness = new DevnetGeometryHarness();
        vm.chainId(31337);
        TableTournamentParametersProvider provider =
            harness.deployTwoLevelProvider();

        for (uint64 level; level < 2; ++level) {
            TournamentParameters memory row =
                provider.tournamentParameters(level);
            assertEq(row.levels, 2);
            // 12 s blocks: 5 minutes and 60 minutes.
            assertEq(Time.Duration.unwrap(row.responseBudget), 25);
            assertEq(Time.Duration.unwrap(row.commitmentBudget), 300);
        }
        TournamentParameters memory root = provider.tournamentParameters(0);
        assertEq(root.log2step, 37);
        assertEq(root.height, 55);
        // No censorship on devnets: the root join's inclusion plus one refill.
        assertEq(Time.Duration.unwrap(root.maxAllowance), 25 + 300 + 2 * 25);
    }
}
