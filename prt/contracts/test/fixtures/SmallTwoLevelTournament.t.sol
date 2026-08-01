// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {
    SmallTwoLevelGeometry,
    SmallTwoLevelParametersProvider,
    SmallTwoLevelTournamentFactory
} from "./SmallTwoLevelTournament.sol";

contract SmallTwoLevelTournamentTest is Test {
    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant RESPONSE_BUDGET = 5;
    uint64 internal constant MAX_ALLOWANCE = 200;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));

    SmallTwoLevelTournamentFactory internal factory;

    function setUp() public {
        vm.roll(START_BLOCK);
        factory = new SmallTwoLevelTournamentFactory(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
    }

    function testRootAndLeafRowsTileAndReachClones() public {
        ITournament root =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        ITournament.TournamentArguments memory rootArgs =
            root.tournamentArguments();

        assertEq(rootArgs.level, 0);
        assertEq(rootArgs.levels, SmallTwoLevelGeometry.LEVELS);
        assertEq(
            rootArgs.commitmentArgs.height, SmallTwoLevelGeometry.ROOT_HEIGHT
        );
        assertEq(
            rootArgs.commitmentArgs.log2step,
            SmallTwoLevelGeometry.ROOT_LOG2_STEP
        );
        assertEq(rootArgs.commitmentArgs.startCycle, 0);
        assertEq(Time.Instant.unwrap(rootArgs.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(rootArgs.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(rootArgs.responseBudget), RESPONSE_BUDGET);
        assertEq(rootArgs.tournamentFactory, address(factory));

        Tree.Node contestedOne = Tree.Node.wrap(bytes32(uint256(0x1001)));
        Tree.Node contestedTwo = Tree.Node.wrap(bytes32(uint256(0x1002)));
        Machine.Hash finalOne = Machine.Hash.wrap(bytes32(uint256(0x2001)));
        Machine.Hash finalTwo = Machine.Hash.wrap(bytes32(uint256(0x2002)));
        uint64 delegatedAllowance = 150;
        uint256 startCycle = 12;
        ITournament leaf = factory.instantiateInner(
            INITIAL_STATE,
            contestedOne,
            finalOne,
            contestedTwo,
            finalTwo,
            Time.Duration.wrap(delegatedAllowance),
            startCycle,
            1,
            IDataProvider(address(0))
        );
        ITournament.TournamentArguments memory leafArgs =
            leaf.tournamentArguments();

        assertEq(leafArgs.level, 1);
        assertEq(leafArgs.levels, SmallTwoLevelGeometry.LEVELS);
        assertEq(
            leafArgs.commitmentArgs.height, SmallTwoLevelGeometry.LEAF_HEIGHT
        );
        assertEq(
            leafArgs.commitmentArgs.log2step,
            SmallTwoLevelGeometry.LEAF_LOG2_STEP
        );
        assertEq(leafArgs.commitmentArgs.startCycle, startCycle);
        assertEq(Time.Duration.unwrap(leafArgs.allowance), delegatedAllowance);
        assertEq(Time.Duration.unwrap(leafArgs.responseBudget), RESPONSE_BUDGET);
        assertEq(leafArgs.tournamentFactory, address(factory));
        assertEq(
            Tree.Node.unwrap(leafArgs.nestedDispute.contestedCommitmentOne),
            Tree.Node.unwrap(contestedOne)
        );
        assertEq(
            Machine.Hash.unwrap(leafArgs.nestedDispute.contestedFinalStateOne),
            Machine.Hash.unwrap(finalOne)
        );
        assertEq(
            Tree.Node.unwrap(leafArgs.nestedDispute.contestedCommitmentTwo),
            Tree.Node.unwrap(contestedTwo)
        );
        assertEq(
            Machine.Hash.unwrap(leafArgs.nestedDispute.contestedFinalStateTwo),
            Machine.Hash.unwrap(finalTwo)
        );

        assertEq(
            rootArgs.commitmentArgs.log2step,
            leafArgs.commitmentArgs.log2step + leafArgs.commitmentArgs.height
        );
    }

    function testRejectsUnsupportedLevelAndWrongLevelOperations() public {
        SmallTwoLevelParametersProvider provider = new SmallTwoLevelParametersProvider(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                SmallTwoLevelParametersProvider.InvalidLevel.selector, 2
            )
        );
        provider.tournamentParameters(2);

        ITournament root =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        vm.expectRevert(ITournament.RequireLeafTournament.selector);
        root.sealLeafMatch(
            _zeroMatch(),
            Tree.ZERO_NODE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            new bytes32[](0)
        );

        ITournament leaf = factory.instantiateInner(
            INITIAL_STATE,
            Tree.Node.wrap(bytes32(uint256(1))),
            Machine.Hash.wrap(bytes32(uint256(2))),
            Tree.Node.wrap(bytes32(uint256(3))),
            Machine.Hash.wrap(bytes32(uint256(4))),
            Time.Duration.wrap(MAX_ALLOWANCE),
            0,
            1,
            IDataProvider(address(0))
        );
        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.sealInnerMatchAndCreateInnerTournament(
            _zeroMatch(),
            Tree.ZERO_NODE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            new bytes32[](0)
        );
    }

    /// @dev Every remaining role-guarded entry point rejects the wrong role
    /// before any match, clock, or child validation.
    function testRejectsRemainingWrongRoleOperations() public {
        ITournament root =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        ITournament leaf = factory.instantiateInner(
            INITIAL_STATE,
            Tree.Node.wrap(bytes32(uint256(1))),
            Machine.Hash.wrap(bytes32(uint256(2))),
            Tree.Node.wrap(bytes32(uint256(3))),
            Machine.Hash.wrap(bytes32(uint256(4))),
            Time.Duration.wrap(MAX_ALLOWANCE),
            0,
            1,
            IDataProvider(address(0))
        );

        vm.expectRevert(ITournament.RequireLeafTournament.selector);
        root.winLeafMatch(_zeroMatch(), Tree.ZERO_NODE, Tree.ZERO_NODE, "");

        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.winInnerTournament(
            ITournament(address(0)), Tree.ZERO_NODE, Tree.ZERO_NODE
        );

        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.eliminateInnerTournament(ITournament(address(0)));

        vm.expectRevert(ITournament.RequireNonRootTournament.selector);
        root.canBeEliminated();

        vm.expectRevert(ITournament.RequireNonRootTournament.selector);
        root.innerTournamentWinner();
    }

    function _zeroMatch() private pure returns (Match.Id memory) {
        return Match.Id({
            commitmentOne: Tree.ZERO_NODE, commitmentTwo: Tree.ZERO_NODE
        });
    }
}
