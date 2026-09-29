// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ClockBudgets} from "src/arbitration-config/ClockBudgets.sol";
import {Time} from "src/tournament/libs/Time.sol";

contract ClockBudgetsTest is Test {
    function _ethereum(uint64 censorship, uint64 commitment)
        internal
        pure
        returns (ClockBudgets.Model memory)
    {
        return ClockBudgets.Model({
            blockMilliseconds: 12_000,
            censorshipSeconds: censorship,
            inclusionSeconds: 5 minutes,
            commitmentSeconds: commitment
        });
    }

    function _unwrap(Time.Duration d) internal pure returns (uint64) {
        return Time.Duration.unwrap(d);
    }

    function testEthereumThreeLevelBudgets() public pure {
        ClockBudgets.Model memory model = _ethereum(1 weeks, 30 minutes);
        assertEq(_unwrap(ClockBudgets.responseBudget(model)), 25);
        assertEq(_unwrap(ClockBudgets.commitmentBudget(model)), 150);
        // The build plus one inclusion each for the join and the propagation.
        assertEq(_unwrap(ClockBudgets.refill(model)), 200);
        // One week, one inclusion for the root join, two refills.
        assertEq(_unwrap(ClockBudgets.maxAllowance(model, 3)), 50_400 + 425);
    }

    function testEthereumTwoLevelBudgets() public pure {
        ClockBudgets.Model memory model = _ethereum(1 weeks, 60 minutes);
        assertEq(_unwrap(ClockBudgets.commitmentBudget(model)), 300);
        assertEq(_unwrap(ClockBudgets.refill(model)), 350);
        assertEq(_unwrap(ClockBudgets.maxAllowance(model, 2)), 50_400 + 375);
    }

    function testSingleLevelAllowanceHasNoRefill() public pure {
        ClockBudgets.Model memory model = _ethereum(1 weeks, 60 minutes);
        assertEq(_unwrap(ClockBudgets.maxAllowance(model, 1)), 50_400 + 25);
    }

    function testFuzzAllowanceHoldsOneRefillPerInnerLevel(
        uint64 blockMilliseconds,
        uint64 censorship,
        uint64 inclusion,
        uint64 commitment,
        uint64 levels
    ) public pure {
        blockMilliseconds = uint64(bound(blockMilliseconds, 1, 60_000));
        censorship = uint64(bound(censorship, 0, 4 weeks));
        inclusion = uint64(bound(inclusion, 0, 1 hours));
        commitment = uint64(bound(commitment, 0, 1 days));
        levels = uint64(bound(levels, 1, 8));
        ClockBudgets.Model memory model = ClockBudgets.Model({
            blockMilliseconds: blockMilliseconds,
            censorshipSeconds: censorship,
            inclusionSeconds: inclusion,
            commitmentSeconds: commitment
        });

        uint64 inclusionBlocks = inclusion * 1000 / blockMilliseconds;
        uint64 commitmentBlocks = commitment * 1000 / blockMilliseconds;
        uint64 refill = commitmentBlocks + 2 * inclusionBlocks;
        assertEq(_unwrap(ClockBudgets.responseBudget(model)), inclusionBlocks);
        assertEq(_unwrap(ClockBudgets.refill(model)), refill);
        assertEq(
            _unwrap(ClockBudgets.maxAllowance(model, levels)),
            censorship * 1000 / blockMilliseconds + inclusionBlocks
                + (levels - 1) * refill
        );
    }
}
