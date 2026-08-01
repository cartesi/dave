// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {
    HistoricalThreeLevelGeometry,
    HistoricalThreeLevelParametersProvider
} from "../fixtures/HistoricalThreeLevelGeometry.sol";

contract HistoricalThreeLevelGeometryTest is Test {
    function testGeometryAndTiling() public pure {
        assertEq(HistoricalThreeLevelGeometry.LEVELS, 3);

        assertEq(HistoricalThreeLevelGeometry.log2step(0), 44);
        assertEq(HistoricalThreeLevelGeometry.height(0), 48);
        assertEq(HistoricalThreeLevelGeometry.log2step(1), 27);
        assertEq(HistoricalThreeLevelGeometry.height(1), 17);
        assertEq(HistoricalThreeLevelGeometry.log2step(2), 0);
        assertEq(HistoricalThreeLevelGeometry.height(2), 27);

        assertEq(
            HistoricalThreeLevelGeometry.height(0)
                + HistoricalThreeLevelGeometry.log2step(0),
            92
        );
        assertEq(
            HistoricalThreeLevelGeometry.height(1),
            HistoricalThreeLevelGeometry.log2step(0)
                - HistoricalThreeLevelGeometry.log2step(1)
        );
        assertEq(
            HistoricalThreeLevelGeometry.height(2),
            HistoricalThreeLevelGeometry.log2step(1)
                - HistoricalThreeLevelGeometry.log2step(2)
        );
    }

    function testProviderReturnsFrozenGeometry() public {
        Time.Duration responseBudget = Time.Duration.wrap(25);
        Time.Duration maxAllowance = Time.Duration.wrap(3600);
        HistoricalThreeLevelParametersProvider provider = new HistoricalThreeLevelParametersProvider(
            responseBudget, maxAllowance
        );

        for (
            uint64 level; level < HistoricalThreeLevelGeometry.LEVELS; ++level) {
            TournamentParameters memory parameters =
                provider.tournamentParameters(level);
            assertEq(parameters.levels, HistoricalThreeLevelGeometry.LEVELS);
            assertEq(
                parameters.log2step,
                HistoricalThreeLevelGeometry.log2step(level)
            );
            assertEq(
                parameters.height, HistoricalThreeLevelGeometry.height(level)
            );
            assertEq(
                Time.Duration.unwrap(parameters.responseBudget),
                Time.Duration.unwrap(responseBudget)
            );
            assertEq(
                Time.Duration.unwrap(parameters.maxAllowance),
                Time.Duration.unwrap(maxAllowance)
            );
        }
    }
}
