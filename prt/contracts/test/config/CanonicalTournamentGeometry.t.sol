// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

pragma solidity ^0.8.17;

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {
    ArbitrationConstants
} from "src/arbitration-config/ArbitrationConstants.sol";
import {
    CanonicalTournamentParametersProvider
} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {Util} from "../Util.sol";

contract CanonicalTournamentGeometryTest is Util {
    CanonicalTournamentParametersProvider internal immutable PROVIDER;
    MultiLevelTournamentFactory internal immutable FACTORY;

    constructor() {
        PROVIDER = new CanonicalTournamentParametersProvider(
            MATCH_EFFORT, MAX_ALLOWANCE
        );
        (FACTORY,) = Util.instantiateCanonicalTournamentFactory();
    }

    function testCheckedInCanonicalTable() public pure {
        assertEq(ArbitrationConstants.LEVELS, 3);
        assertEq(ArbitrationConstants.log2step(0), 44);
        assertEq(ArbitrationConstants.height(0), 48);
        assertEq(ArbitrationConstants.log2step(1), 27);
        assertEq(ArbitrationConstants.height(1), 17);
        assertEq(ArbitrationConstants.log2step(2), 0);
        assertEq(ArbitrationConstants.height(2), 27);
    }

    function testCanonicalProviderRejectsZeroMaxAllowance() public {
        vm.expectRevert(
            CanonicalTournamentParametersProvider.MaxAllowanceCannotBeZero
            .selector
        );
        new CanonicalTournamentParametersProvider(
            MATCH_EFFORT, Time.ZERO_DURATION
        );
    }

    function testCanonicalProviderAcceptsZeroMatchEffort() public {
        CanonicalTournamentParametersProvider provider = new CanonicalTournamentParametersProvider(
            Time.ZERO_DURATION, MAX_ALLOWANCE
        );
        TournamentParameters memory parameters =
            provider.tournamentParameters(0);

        assertEq(Time.Duration.unwrap(parameters.matchEffort), 0);
        assertEq(
            Time.Duration.unwrap(parameters.maxAllowance),
            Time.Duration.unwrap(MAX_ALLOWANCE)
        );
    }

    function testCanonicalProviderRowsAndTiling() public view {
        uint64 levels = ArbitrationConstants.LEVELS;
        assertGt(levels, 0);

        uint64 previousStride;
        for (uint64 level; level < levels; ++level) {
            TournamentParameters memory parameters =
                PROVIDER.tournamentParameters(level);

            assertEq(parameters.levels, levels);
            assertEq(parameters.log2step, ArbitrationConstants.log2step(level));
            assertEq(parameters.height, ArbitrationConstants.height(level));
            assertEq(
                Time.Duration.unwrap(parameters.matchEffort),
                Time.Duration.unwrap(MATCH_EFFORT)
            );
            assertEq(
                Time.Duration.unwrap(parameters.maxAllowance),
                Time.Duration.unwrap(MAX_ALLOWANCE)
            );

            assertGt(parameters.height, 0);
            assertLt(parameters.height, 256);
            assertLt(parameters.log2step, 256);
            if (level == 0) {
                assertEq(uint256(parameters.height) + parameters.log2step, 92);
            } else {
                assertEq(
                    previousStride, parameters.height + parameters.log2step
                );
            }
            previousStride = parameters.log2step;
        }

        assertEq(previousStride, 0);
    }

    function testFactoryRootUsesCanonicalRowZero() public {
        ITournament root =
            FACTORY.instantiate(ONE_STATE, IDataProvider(address(0)));

        (uint64 levels, uint64 level, uint64 log2step, uint64 height) =
            root.tournamentLevelConstants();
        assertEq(levels, ArbitrationConstants.LEVELS);
        assertEq(level, 0);
        assertEq(log2step, ArbitrationConstants.log2step(0));
        assertEq(height, ArbitrationConstants.height(0));
    }
}
