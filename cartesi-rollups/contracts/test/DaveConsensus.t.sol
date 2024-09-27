// Copyright 2023 Cartesi Pte. Ltd.

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {MultiLevelTournamentFactory} from "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import {TopTournamentFactory} from "prt-contracts/tournament/factories/multilevel/TopTournamentFactory.sol";
import {MiddleTournamentFactory} from "prt-contracts/tournament/factories/multilevel/MiddleTournamentFactory.sol";
import {BottomTournamentFactory} from "prt-contracts/tournament/factories/multilevel/BottomTournamentFactory.sol";

contract DaveConsensusTest is Test {
    function testDummy() external {
        new MultiLevelTournamentFactory(
            new TopTournamentFactory(), new MiddleTournamentFactory(), new BottomTournamentFactory()
        );
    }
}
