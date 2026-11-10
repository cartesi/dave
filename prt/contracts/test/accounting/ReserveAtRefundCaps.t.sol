// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Gas} from "src/tournament/libs/Gas.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev The work reserve with every refund at its action cap, on the
/// production Tournament composed over a root and its leaf children
/// (prt-refund-accounting.md). RefundReserve.t.sol owns the algebra and
/// height-one traces at the work price, where no cap binds. Here the fee is
/// far above the cap, one caller collects every refund, and the pranked
/// claimers pay the bonds.
///
/// Establishes, on three priced traces: no refund exceeds its action cap,
/// the refunds of one match stay within one bond, a finished tournament
/// still holds its winner's bond, and refunds, winner payment and burn
/// account for every bond paid in. It does not establish the property over
/// arrival schedules (ProductionReserveSingleLevel.t.sol and
/// ProductionReserveTwoLevel.t.sol sample those), receipt gas, or the cost
/// of a real leaf proof.
contract ReserveAtRefundCapsTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    /// @dev The balances a trace settles against.
    struct Balances {
        uint256 honest;
        uint256 sybil;
        uint256 sybilTwo;
        uint256 worker;
        uint256 burned;
    }

    uint256 workerBalance;

    /// @dev This contract sends every progress action, so it is paid every
    /// refund.
    receive() external payable {}

    function _balances() internal view returns (Balances memory) {
        return Balances({
            honest: HONEST.balance,
            sybil: SYBIL.balance,
            sybilTwo: SYBIL_TWO.balance,
            worker: address(this).balance,
            burned: address(0).balance
        });
    }

    /// @dev What this contract was paid since `workerBalance` was last set,
    /// here or by the trace.
    function _refunded() internal returns (uint256 refund) {
        refund = address(this).balance - workerBalance;
        workerBalance = address(this).balance;
    }

    /// @dev Far above the work price, so that units times price exceeds
    /// every action cap, the leaf proof's included.
    function _priceAboveEveryCap() internal {
        vm.fee(10_000_000 gwei);
        vm.txGasPrice(20_000_000 gwei);
    }

    function _cap(uint256 allocation) internal pure returns (uint256) {
        return Bond.actionRefundCap(allocation);
    }

    /// @dev One Sybil per level and the longest legal path at each level:
    /// the Sybil's two forfeited bonds leave as refunds, each tournament
    /// keeps exactly one bond, and the winner is paid exactly that.
    function testTraceEveryCapBindsAndWinnerKeepsExactlyOneBond() public {
        vm.roll(100);
        _priceAboveEveryCap();
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        uint256 rootBond = root.bondValue();
        Balances memory start = _balances();

        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        assertEq(address(root).balance, 2 * rootBond);

        workerBalance = address(this).balance;
        advanceToSeal(root, hRoot, sRoot);
        assertEq(_refunded(), _cap(Gas.ADVANCE_MATCH));

        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        assertEq(
            _refunded(), _cap(Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT)
        );
        assertEq(address(child).balance, 0, "a parent funds no child");

        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        uint256 childBond = child.bondValue();
        rollBy(T + 1);
        join(child, sChild, SYBIL);
        join(child, hChild, HONEST);
        assertEq(address(child).balance, 2 * childBond);

        advanceToSeal(child, sChild, hChild);
        assertEq(_refunded(), _cap(Gas.ADVANCE_MATCH));

        uint256 divergence = sealLeaf(child, sChild, hChild);
        assertEq(_refunded(), _cap(Gas.SEAL_LEAF_MATCH));

        prove(child, sChild, hChild, hChild, divergence);
        assertEq(_refunded(), _cap(Gas.WIN_LEAF_MATCH));
        assertEq(address(child).balance, childBond, "child reserve");

        rollTo(closureOf(child));
        propagate(root, child, hRoot);
        assertEq(_refunded(), _cap(Gas.WIN_INNER_TOURNAMENT));
        assertEq(address(root).balance, rootBond, "root reserve");

        rollTo(closureOf(root));
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );

        assertTrue(child.tryRecoveringBond());
        assertTrue(root.tryRecoveringBond());
        assertEq(address(child).balance, 0);
        assertEq(address(root).balance, 0);
        assertEq(address(0).balance, start.burned, "nothing burned");
        assertEq(HONEST.balance, start.honest, "made whole, no bounty");
        assertEq(start.sybil - SYBIL.balance, rootBond + childBond);
        assertEq(address(this).balance - start.worker, rootBond + childBond);
    }

    /// @dev Four root claims and mixed terminals: the inner elimination of
    /// a child nobody joined, and a direct timeout win.
    function testTraceMixedTerminalsAtCapKeepReserveAndConserve() public {
        vm.roll(100);
        _priceAboveEveryCap();
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        uint256 bond = root.bondValue();
        SmallFullTree.Data memory hRoot = rootTreeOf(fineLeaves(1));
        SmallFullTree.Data memory s1 = rootTreeOf(fineLeaves(1, 10, 2));
        SmallFullTree.Data memory s2 = rootTreeOf(fineLeaves(1, 3, 3));
        SmallFullTree.Data memory s3 = rootTreeOf(fineLeaves(1, 6, 4));

        Balances memory start = _balances();

        join(root, hRoot, HONEST); // dangling
        join(root, s1, SYBIL); // match (H, S1)
        join(root, s2, SYBIL_TWO); // dangling
        join(root, s3, THIRD); // match (S2, S3)
        uint256 joins = 4;
        uint256 created = 2;
        assertEq(address(root).balance, joins * bond);

        // The Sybil pair runs to an inner seal; nobody joins its child.
        advanceToSeal(root, s2, s3);
        (InspectableTournament emptyChild,) = sealInner(root, s2, s3);
        assertGe(address(root).balance, (joins - created) * bond);

        // The honest pair: one advance is all height two allows, then the
        // Sybil, whose turn it is to seal, lets its clock run out.
        advanceToSeal(root, hRoot, s1);
        assertGe(address(root).balance, (joins - created) * bond);

        rollTo(closureOf(emptyChild));
        eliminateChild(root, emptyChild);
        assertGe(address(root).balance, (joins - created) * bond);

        uint64 deadline = Time.Instant
        .unwrap(clockOf(root, s1.root()).startInstant)
        + allowanceOf(root, s1.root());
        if (deadline > vm.getBlockNumber()) {
            rollTo(deadline);
        }
        timeoutWin(root, hRoot, s1, hRoot);
        assertEq(liveMatches(root), 0);
        assertTrue(dangling(root).eq(hRoot.root()));

        uint256 refunds = address(this).balance - start.worker;
        uint256 everyCap = _cap(Gas.ADVANCE_MATCH)
            + _cap(Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT)
            + _cap(Gas.ELIMINATE_INNER_TOURNAMENT) + _cap(Gas.ADVANCE_MATCH)
            + _cap(Gas.WIN_MATCH_BY_TIMEOUT);
        assertEq(refunds, everyCap, "every refund at its cap");
        assertLe(refunds, created * bond, "refunds within one bond a match");

        uint256 pre = address(root).balance;
        assertEq(pre, joins * bond - refunds);
        assertGe(pre, bond, "one bond reserved for the winner");

        if (closureOf(root) > vm.getBlockNumber()) {
            rollTo(closureOf(root));
        }
        assertTrue(root.tryRecoveringBond());
        uint256 paid = HONEST.balance - (start.honest - bond);
        assertEq(paid, bond + (pre - bond) / 10);
        uint256 burned = address(0).balance - start.burned;
        assertEq(address(root).balance, 0);
        assertEq(refunds + paid + burned, joins * bond, "conservation");
        assertGe(burned, 9 * (paid - bond), "nine tenths of residual burned");
    }

    /// @dev The tightest root case: one match fewer than joins, and every
    /// match consumes its whole reserve. Three root claims and two complete
    /// inner paths, the second after a re-pairing inside the first
    /// propagation. The root ends with exactly one bond, whoever wins.
    function testTraceTwoFullInnerPathsLeaveExactlyOneRootBond() public {
        vm.roll(100);
        _priceAboveEveryCap();
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        uint256 rootBond = root.bondValue();
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory f1 = fineLeaves(1, 10, 2);
        Tree.Node[] memory f2 = fineLeaves(1, 6, 3);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory s1Root = rootTreeOf(f1);
        SmallFullTree.Data memory s2Root = rootTreeOf(f2);
        Balances memory start = _balances();

        join(root, hRoot, HONEST);
        join(root, s1Root, SYBIL); // match (H, S1)
        join(root, s2Root, SYBIL_TWO); // dangling
        assertEq(address(root).balance, 3 * rootBond);

        advanceToSeal(root, hRoot, s1Root);
        (InspectableTournament child1, uint256 seg1) =
            sealInner(root, hRoot, s1Root);
        uint256 leafBond = child1.bondValue();
        SmallFullTree.Data memory hChild = childTreeOf(honest, seg1);
        SmallFullTree.Data memory s1Child = childTreeOf(f1, seg1);
        rollBy(T + 1);
        join(child1, s1Child, SYBIL);
        join(child1, hChild, HONEST);
        advanceToSeal(child1, s1Child, hChild);
        uint256 d = sealLeaf(child1, s1Child, hChild);
        prove(child1, s1Child, hChild, hChild, d);
        assertEq(address(child1).balance, leafBond);

        rollTo(closureOf(child1));
        propagate(root, child1, hRoot); // H re-pairs with the dangling S2
        assertEq(liveMatches(root), 1);
        assertEq(address(root).balance, 2 * rootBond);

        advanceToSeal(root, s2Root, hRoot);
        (InspectableTournament child2, uint256 seg2) =
            sealInner(root, s2Root, hRoot);
        SmallFullTree.Data memory s2Child = childTreeOf(f2, seg2);
        join(child2, s2Child, SYBIL_TWO); // only one side shows up
        rollTo(closureOf(child2));
        propagate(root, child2, s2Root);

        assertEq(liveMatches(root), 0);
        assertTrue(dangling(root).eq(s2Root.root()));
        assertEq(address(root).balance, rootBond, "exactly one bond left");
        assertEq(
            address(this).balance - start.worker,
            2 * rootBond + leafBond,
            "two root reserves and one leaf reserve left as refunds"
        );

        if (closureOf(root) > vm.getBlockNumber()) {
            rollTo(closureOf(root));
        }
        Balances memory settled = _balances();
        assertTrue(root.tryRecoveringBond());
        assertTrue(child1.tryRecoveringBond());
        assertTrue(child2.tryRecoveringBond());
        assertEq(SYBIL_TWO.balance - settled.sybilTwo, rootBond + leafBond);
        assertEq(HONEST.balance - settled.honest, leafBond);
        assertEq(
            address(0).balance, settled.burned, "nothing left to burn anywhere"
        );
        assertEq(address(root).balance, 0);
        assertEq(address(child1).balance, 0);
        assertEq(address(child2).balance, 0);
    }
}
