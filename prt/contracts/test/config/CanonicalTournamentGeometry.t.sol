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
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ClockBudgets} from "src/arbitration-config/ClockBudgets.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {Util} from "../Util.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

contract CanonicalTournamentGeometryTest is Util {
    CanonicalTournamentParametersProvider internal immutable PROVIDER;
    MultiLevelTournamentFactory internal immutable FACTORY;

    constructor() {
        PROVIDER = new CanonicalTournamentParametersProvider(
            CANONICAL_BLOCK_MILLISECONDS,
            CANONICAL_CENSORSHIP_SECONDS,
            CANONICAL_INCLUSION_SECONDS
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
        assertEq(ArbitrationConstants.COMMITMENT_BUDGET, 30 minutes);
    }

    function _canonicalModel()
        internal
        pure
        returns (ClockBudgets.Model memory)
    {
        return ClockBudgets.Model({
            blockMilliseconds: CANONICAL_BLOCK_MILLISECONDS,
            censorshipSeconds: CANONICAL_CENSORSHIP_SECONDS,
            inclusionSeconds: CANONICAL_INCLUSION_SECONDS,
            commitmentSeconds: ArbitrationConstants.COMMITMENT_BUDGET
        });
    }

    function testCanonicalProviderRejectsZeroMaxAllowance() public {
        vm.expectRevert(
            CanonicalTournamentParametersProvider.MaxAllowanceCannotBeZero
            .selector
        );
        // Blocks longer than every budget round all of them to zero.
        new CanonicalTournamentParametersProvider(1 hours * 1000, 0, 0);
    }

    function testCanonicalProviderRejectsZeroBlockTime() public {
        vm.expectRevert(ClockBudgets.BlockTimeCannotBeZero.selector);
        new CanonicalTournamentParametersProvider(
            0, CANONICAL_CENSORSHIP_SECONDS, CANONICAL_INCLUSION_SECONDS
        );
    }

    function testCanonicalProviderAcceptsZeroResponseBudget() public {
        CanonicalTournamentParametersProvider provider = new CanonicalTournamentParametersProvider(
            CANONICAL_BLOCK_MILLISECONDS, CANONICAL_CENSORSHIP_SECONDS, 0
        );
        TournamentParameters memory parameters =
            provider.tournamentParameters(0);

        ClockBudgets.Model memory model = _canonicalModel();
        model.inclusionSeconds = 0;
        assertEq(Time.Duration.unwrap(parameters.responseBudget), 0);
        assertEq(
            Time.Duration.unwrap(parameters.maxAllowance),
            Time.Duration
                .unwrap(
                    ClockBudgets.maxAllowance(
                        model, ArbitrationConstants.LEVELS
                    )
                )
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
            ClockBudgets.Model memory model = _canonicalModel();
            assertEq(
                Time.Duration.unwrap(parameters.responseBudget),
                Time.Duration.unwrap(ClockBudgets.responseBudget(model))
            );
            assertEq(
                Time.Duration.unwrap(parameters.commitmentBudget),
                Time.Duration.unwrap(ClockBudgets.commitmentBudget(model))
            );
            assertEq(
                Time.Duration.unwrap(parameters.maxAllowance),
                Time.Duration
                    .unwrap(
                        ClockBudgets.maxAllowance(
                            model, ArbitrationConstants.LEVELS
                        )
                    )
            );
            // At 12 s blocks: 5 minutes, 30 minutes, and 8 hours plus the
            // root join's inclusion plus two refills of 30 min + 2 x 5 min.
            assertEq(Time.Duration.unwrap(parameters.responseBudget), 25);
            assertEq(Time.Duration.unwrap(parameters.commitmentBudget), 150);
            assertEq(
                Time.Duration.unwrap(parameters.maxAllowance),
                2400 + 25 + 2 * 200
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

        (
            ITournament.TournamentKind kind,
            uint64 level,
            uint64 log2step,
            uint64 height
        ) = root.tournamentLevelConstants();
        assertEq(uint8(kind), uint8(ITournament.TournamentKind.NON_LEAF));
        assertEq(level, 0);
        assertEq(log2step, ArbitrationConstants.log2step(0));
        assertEq(height, ArbitrationConstants.height(0));

        ITournament.TournamentArguments memory args = root.tournamentArguments();
        assertEq(Time.Duration.unwrap(args.responseBudget), 25);
        assertEq(Time.Duration.unwrap(args.commitmentBudget), 150);
    }
}
