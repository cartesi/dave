// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/console.sol";
import "forge-std/Test.sol";

import "prt-contracts/tournament/abstracts/RootTournament.sol";
import "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import "prt-contracts/arbitration-config/CanonicalConstants.sol";

import "./Util.sol";

pragma solidity ^0.8.0;

contract TournamentFactoryTest is Util, Test {
    SingleLevelTournamentFactory singleLevelfactory;
    MultiLevelTournamentFactory multiLevelfactory;

    function setUp() public {
        singleLevelfactory = Util.instantiateSingleLevelTournamentFactory();
        (multiLevelfactory,) = Util.instantiateTournamentFactory();
    }

    function testRootTournament() public {
        RootTournament rootTournament = RootTournament(
            address(
                singleLevelfactory.instantiate(
                    Util.ONE_STATE, IDataProvider(address(0))
                )
            )
        );

        (uint64 _max_level, uint64 _level, uint64 _log2step, uint64 _height) =
            rootTournament.tournamentLevelConstants();

        assertEq(_level, 0, "level should be 0");
        assertEq(
            _log2step,
            ArbitrationConstants.log2step(_level),
            "log2step should match"
        );
        assertEq(
            _height, ArbitrationConstants.height(_level), "height should match"
        );

        rootTournament = RootTournament(
            address(
                multiLevelfactory.instantiateTop(
                    Util.ONE_STATE, IDataProvider(address(0))
                )
            )
        );

        (_max_level, _level, _log2step, _height) =
            rootTournament.tournamentLevelConstants();

        assertEq(_level, 0, "level should be 0");
        assertEq(
            _log2step,
            ArbitrationConstants.log2step(_level),
            "log2step should match"
        );
        assertEq(
            _height, ArbitrationConstants.height(_level), "height should match"
        );
    }
}
