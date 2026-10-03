// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {DeploymentScript, Seconds} from "../script/Deployment.s.sol";
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

contract DeploymentHarness is DeploymentScript {
    function inclusionBudgetInSeconds() external pure returns (uint64) {
        return Seconds.unwrap(_getInclusionBudget());
    }

    /// @notice Deploy the provider exactly as `run` encodes it.
    function deployCanonicalProvider()
        external
        returns (CanonicalTournamentParametersProvider provider)
    {
        _registerChains();
        _registerChainKinds();
        bytes memory code = abi.encodePacked(
            type(CanonicalTournamentParametersProvider).creationCode,
            _canonicalProviderArguments()
        );
        assembly ("memory-safe") {
            provider := create(0, add(code, 32), mload(code))
        }
        require(address(provider) != address(0), "provider deployment failed");
    }
}

contract DeploymentTest is Test {
    uint64 constant RESPONSE_BLOCKS = (5 minutes) / (12 seconds);
    uint64 constant COMMITMENT_BLOCKS =
        ArbitrationConstants.COMMITMENT_BUDGET / (12 seconds);
    // One inclusion for the root join, and one refill (the build plus two
    // inclusions) per inner level of the checked-in table.
    uint64 constant PENDING = RESPONSE_BLOCKS
        + (ArbitrationConstants.LEVELS - 1)
        * (COMMITMENT_BLOCKS + 2 * RESPONSE_BLOCKS);

    function _rowZero(uint256 chainId)
        internal
        returns (TournamentParameters memory)
    {
        DeploymentHarness harness = new DeploymentHarness();
        vm.chainId(chainId);
        return harness.deployCanonicalProvider().tournamentParameters(0);
    }

    function _assertBudgets(
        TournamentParameters memory row,
        uint64 censorshipBlocks
    ) internal pure {
        assertEq(Time.Duration.unwrap(row.responseBudget), RESPONSE_BLOCKS);
        assertEq(Time.Duration.unwrap(row.commitmentBudget), COMMITMENT_BLOCKS);
        assertEq(
            Time.Duration.unwrap(row.maxAllowance), censorshipBlocks + PENDING
        );
    }

    function testInclusionBudget() public {
        assertEq(new DeploymentHarness().inclusionBudgetInSeconds(), 5 minutes);
    }

    function testDevnetClockCalibration() public {
        // Devnets tolerate no censorship.
        _assertBudgets(_rowZero(31337), 0);
    }

    function testEthereumMainnetClockCalibration() public {
        _assertBudgets(_rowZero(1), (1 weeks) / (12 seconds));
    }

    function testEthereumSepoliaClockCalibration() public {
        _assertBudgets(_rowZero(11155111), (8 hours) / (12 seconds));
    }

    // Arbitrum's NUMBER is the parent chain's block number.
    function testArbitrumOneClockCalibration() public {
        _assertBudgets(_rowZero(42161), (1 weeks) / (12 seconds));
    }

    function testArbitrumSepoliaClockCalibration() public {
        _assertBudgets(_rowZero(421614), (8 hours) / (12 seconds));
    }
}
