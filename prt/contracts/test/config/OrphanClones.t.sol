// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {
    SmallTwoLevelGeometry,
    SmallTwoLevelTournamentFactory
} from "test/fixtures/SmallTwoLevelTournament.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Lead, not an exploit: what an orphan clone can look like and what
/// it cannot do (dispute-game.md, Tournament roles and configuration;
/// reviews/2026-11-10-contracts-audit, N-03).
///
/// The factory's `instantiateInner` is permissionless and checks no
/// argument, so a clone that no parent created can carry any level and any
/// allowance:
///
/// - level zero gives a root-kind clone with a caller-chosen window, base
///   cycle and provider, a nonzero nested dispute, and no
///   `TournamentCreated`;
/// - an allowance no parent would pass gives a clone that never closes, so
///   a bond joined there is never recovered. FactoryNonceReorg.t.sol's twin
///   has its child's arguments and returns the stranded bond when it
///   closes; a twin with a chosen allowance does not.
///
/// On chain an orphan has no authority: a parent neither calls nor refunds
/// a child it did not record. What the traces price is a client that joins
/// an address it has not read after finality, at one clone deployment plus,
/// for a cached address, a reorg. The node follows tournaments from the
/// consensus through each parent's `NewInnerTournament` and joins only from
/// finalized state, so it is not exposed. Small injected geometry; the
/// traces say nothing about any client's behavior.
contract OrphanClonesTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    /// @dev Longer than any chain will run: a century of 12 s blocks is
    /// about 2^28 blocks.
    Time.Duration constant NEVER = Time.Duration.wrap(uint64(1) << 62);
    uint256 constant A_CENTURY_OF_BLOCKS = 263_000_000;

    function testTraceLevelZeroOrphanIsARootWithoutCreationEvent() public {
        vm.roll(1000);
        SmallTwoLevelTournamentFactory factory =
            twoLevelFactory(G, T, ALLOWANCE);
        uint256 baseCycle = uint256(123) << SmallTwoLevelGeometry.ROOT_LOG2_STEP;

        vm.recordLogs();
        vm.prank(SYBIL);
        (ITournament orphan, ITournament.TournamentDescriptor memory d) = factory.instantiateInner(
            Machine.Hash.wrap(bytes32(uint256(0x11))),
            Tree.Node.wrap(bytes32(uint256(0x22))),
            Machine.Hash.wrap(bytes32(uint256(0x33))),
            Tree.Node.wrap(bytes32(uint256(0x44))),
            Machine.Hash.wrap(bytes32(uint256(0x55))),
            Time.Duration.wrap(7),
            baseCycle,
            0,
            IDataProvider(address(0xdead))
        );
        assertEq(vm.getRecordedLogs().length, 0, "no TournamentCreated");

        // Row zero's kind and geometry; everything else is the caller's.
        assertEq(d.level, 0);
        assertEq(uint8(d.kind), uint8(ITournament.TournamentKind.NON_LEAF));
        assertEq(d.height, SmallTwoLevelGeometry.ROOT_HEIGHT);
        assertEq(d.log2Stride, SmallTwoLevelGeometry.ROOT_LOG2_STEP);
        assertEq(d.baseCycle, baseCycle);
        assertEq(Time.Duration.unwrap(d.allowance), 7);
        ITournament.TournamentArguments memory args =
            orphan.tournamentArguments();
        assertEq(
            Tree.Node.unwrap(args.nestedDispute.contestedCommitmentOne),
            bytes32(uint256(0x22))
        );
        assertEq(address(args.provider), address(0xdead));

        // It behaves as a root: any final state joins, there is no inner
        // result, and it reports ROOT_WINNER on its own.
        SmallFullTree.Data memory claim = seededTree("orphan", ROOT_HEIGHT);
        join(InspectableTournament(address(orphan)), claim, SYBIL);
        vm.expectRevert(ITournament.RequireNonRootTournament.selector);
        orphan.innerResult();
        vm.roll(1007);
        ITournament.TournamentStandingView memory s =
            orphan.tournamentStanding();
        assertEq(
            uint8(s.standing), uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertEq(
            Machine.Hash.unwrap(s.finalState),
            Machine.Hash.unwrap(claim.finalState())
        );
    }

    /// @dev A level-zero clone skips the contested-state check, so a root
    /// join binds only the commitment height. The orphan differs from the
    /// genuine root in its allowance alone, and the join it takes is locked.
    function testTraceRootJoinIntoNeverClosingLevelZeroOrphanLocksTheBond()
        public
    {
        vm.roll(100);
        SmallTwoLevelTournamentFactory factory =
            twoLevelFactory(G, T, ALLOWANCE);
        vm.prank(SYBIL);
        (ITournament orphan,) = factory.instantiateInner(
            INITIAL_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            NEVER,
            0,
            0,
            IDataProvider(address(0))
        );
        InspectableTournament genuine = newRoot(factory);
        uint256 bond = orphan.bondValue();
        assertEq(bond, genuine.bondValue());

        SmallFullTree.Data memory hRoot = rootTreeOf(fineLeaves(1));
        uint256 before = HONEST.balance;
        join(InspectableTournament(address(orphan)), hRoot, HONEST);
        assertEq(before - HONEST.balance, bond);

        vm.roll(vm.getBlockNumber() + A_CENTURY_OF_BLOCKS);
        _assertBondLocked(orphan, bond);
    }

    /// @dev The reorg of FactoryNonceReorg.t.sol with one argument changed:
    /// the clone that takes the cached child address copies everything but
    /// the allowance. The bond is the same, so the client's prepared join
    /// carries the right value, and it stays there.
    function testTraceReorgTwinWithChosenAllowanceLocksTheBond() public {
        vm.roll(100);
        SmallTwoLevelTournamentFactory factory =
            twoLevelFactory(G, T, ALLOWANCE);
        InspectableTournament root = newRoot(factory);
        Tree.Node[] memory honest = fineLeaves(1);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(fineLeaves(1, 10, 2));
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        uint256 sealBlock = vm.getBlockNumber();
        uint256 snapshot = vm.snapshotState();

        // Block B: the seal. A client caches the child from its event.
        (InspectableTournament cached, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        ITournament.TournamentArguments memory args =
            cached.tournamentArguments();

        // B is reorged out. In B' the attacker takes the factory nonce
        // before the re-included seal.
        vm.revertToState(snapshot);
        vm.roll(sealBlock);
        vm.prank(SYBIL);
        (ITournament twin,) = factory.instantiateInner(
            args.commitmentArgs.initialHash,
            args.nestedDispute.contestedCommitmentOne,
            args.nestedDispute.contestedFinalStateOne,
            args.nestedDispute.contestedCommitmentTwo,
            args.nestedDispute.contestedFinalStateTwo,
            NEVER,
            args.commitmentArgs.startCycle,
            args.level,
            args.provider
        );
        assertEq(address(twin), address(cached), "cached address reassigned");
        (InspectableTournament real,) = sealInner(root, hRoot, sRoot);
        assertTrue(address(real) != address(cached));
        uint256 bond = twin.bondValue();
        assertEq(bond, real.bondValue());

        rollBy(T + 1);
        uint256 before = HONEST.balance;
        join(
            InspectableTournament(address(twin)),
            childTreeOf(honest, segment),
            HONEST
        );
        assertEq(before - HONEST.balance, bond);
        assertEq(address(twin).balance, bond);

        vm.roll(vm.getBlockNumber() + A_CENTURY_OF_BLOCKS);
        _assertBondLocked(twin, bond);
    }

    /// @dev Refuted: a parent consumes, calls, or pays a refund for a child
    /// it did not record. An orphan with the recorded child's exact
    /// arguments is never called, both parent verbs revert, and no balance
    /// moves; the same holds for an address that is no clone at all.
    function testRefutedParentCallsOrRefundsAnUnrecordedChild() public {
        vm.roll(100);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        SmallTwoLevelTournamentFactory factory =
            twoLevelFactory(G, T, ALLOWANCE);
        InspectableTournament root = newRoot(factory);
        SmallFullTree.Data memory hRoot = rootTreeOf(fineLeaves(1));
        SmallFullTree.Data memory sRoot = rootTreeOf(fineLeaves(1, 10, 3));
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child,) = sealInner(root, hRoot, sRoot);
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        (ITournament orphan,) = factory.instantiateInner(
            args.commitmentArgs.initialHash,
            args.nestedDispute.contestedCommitmentOne,
            args.nestedDispute.contestedFinalStateOne,
            args.nestedDispute.contestedCommitmentTwo,
            args.nestedDispute.contestedFinalStateTwo,
            args.allowance,
            args.commitmentArgs.startCycle,
            args.level,
            args.provider
        );
        uint256 rootBalance = address(root).balance;
        uint256 callerBalance = address(this).balance;
        (Tree.Node l, Tree.Node r) = hRoot.children(ROOT_HEIGHT, 0);

        vm.expectCall(
            address(orphan), abi.encodeCall(ITournament.innerResult, ()), 0
        );
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        root.winInnerTournament(orphan, l, r);
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        root.eliminateInnerTournament(orphan);
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        root.eliminateInnerTournament(ITournament(address(this)));

        assertEq(address(root).balance, rootBalance);
        assertEq(address(this).balance, callerBalance);
    }

    /// @dev The clone still accepts joins and has no exit: recovery needs
    /// closure, and nothing else pays out.
    function _assertBondLocked(ITournament orphan, uint256 bond) internal {
        (ITournament.BondDisposition disposition,,) = orphan.bondRecovery();
        assertEq(
            uint8(disposition),
            uint8(ITournament.BondDisposition.TOURNAMENT_RUNNING)
        );
        vm.expectRevert(ITournament.TournamentNotFinished.selector);
        orphan.tryRecoveringBond();
        assertTrue(orphan.tournamentStanding().acceptsJoins);
        assertEq(address(orphan).balance, bond, "bond locked");
    }
}
