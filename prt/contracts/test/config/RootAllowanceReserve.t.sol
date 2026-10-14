// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {ClockBudgets} from "src/arbitration-config/ClockBudgets.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev F-01 (reviews/2026-10-13-prt-cyber-verification). The root join's
/// latency is deducted with no discount, and a response is accepted only
/// while elapsed < balance, its G discount applying after acceptance, so the
/// clock must hold j0 + l + c at once. A one-level allowance of C + G lost
/// the honest commitment to one Sybil at any j0 + l >= G with each latency
/// inside G. The deployed formula now holds one inclusion in reserve for the
/// action in flight; the regression drives the same schedule through
/// ClockBudgets.maxAllowance at one level and the honest commitment wins.
/// At two levels the pending delegation's unspent propagation inclusion
/// covers the in-flight latency even without the reserve, which the control
/// at the end shows.
contract RootAllowanceReserveTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant BLOCK_MS = 12_000;

    /// The schedule: a Sybil waits dangling from the start, the honest join
    /// lands at G - 1, the Sybil answers in the same block, and the honest
    /// response lands after C of censorship plus one block.
    function _run(uint64 c, uint64 allowance)
        internal
        returns (
            InspectableTournament root,
            SmallFullTree.Data memory sybil,
            SmallFullTree.Data memory honest
        )
    {
        vm.roll(100);
        root = newRoot(singleLevelFactory(G, allowance));
        uint256 start = block.number;

        sybil = seededTree(bytes32("sybil"), 3);
        honest = seededTree(bytes32("honest"), 3);

        join(root, sybil, SYBIL);
        rollTo(start + G - 1);
        join(root, honest, HONEST);
        assertEq(allowanceOf(root, honest.root()), allowance - (G - 1));
        advance(root, sybil, honest);
        rollBy(c + 1);
    }

    function extAdvance(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) external {
        advance(t, one, two);
    }

    /// The defect at the former formula C + G: eliminated with every latency
    /// inside G and exactly C of censorship, zero included.
    function _traceWithoutReserve(uint64 c) internal {
        (
            InspectableTournament root,
            SmallFullTree.Data memory sybil,
            SmallFullTree.Data memory honest
        ) = _run(c, c + G);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        this.extAdvance(root, sybil, honest);

        timeoutWin(root, sybil, honest, sybil);
        rollTo(closureOf(root));
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(sybil.root()));
    }

    function testTraceOneLevelAllowanceWithoutReserveZeroCensorship() public {
        _traceWithoutReserve(0);
    }

    function testTraceOneLevelAllowanceWithoutReserveFullCensorship() public {
        _traceWithoutReserve(10);
    }

    /// The deployed formula at one level, through ClockBudgets: the response
    /// lands, the Sybil then runs its clock out, and the honest side wins.
    function _regressionAtFormula(uint64 c) internal {
        ClockBudgets.Model memory model = ClockBudgets.Model({
            blockMilliseconds: BLOCK_MS,
            censorshipSeconds: c * (BLOCK_MS / 1000),
            inclusionSeconds: G * (BLOCK_MS / 1000),
            commitmentSeconds: 0
        });
        uint64 allowance =
            Time.Duration.unwrap(ClockBudgets.maxAllowance(model, 1));
        assertEq(allowance, c + 2 * G);

        (
            InspectableTournament root,
            SmallFullTree.Data memory sybil,
            SmallFullTree.Data memory honest
        ) = _run(c, allowance);
        advance(root, sybil, honest);
        assertEq(
            uint8(classify(root, sybil, honest)),
            uint8(ITournament.MatchTimeoutOutcome.NONE)
        );

        // The Sybil, at its seal turn, lets its clock expire; by then the
        // root is already closed, so the timeout win finishes it.
        rollBy(allowanceOf(root, sybil.root()));
        timeoutWin(root, sybil, honest, honest);
        if (vm.getBlockNumber() < closureOf(root)) {
            rollTo(closureOf(root));
        }
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(honest.root()));
    }

    function testRegressionOneLevelFormulaHoldsInFlightLatencyZeroCensorship()
        public
    {
        _regressionAtFormula(0);
    }

    function testRegressionOneLevelFormulaHoldsInFlightLatencyFullCensorship()
        public
    {
        _regressionAtFormula(10);
    }

    /// Control: the same worst-latency schedule at L = 2 and C = 0, with the
    /// budget one inclusion below the formula (T + 3G), survives with a
    /// three-block margin (j0 + j1 + l = T + 3G - 3): the pending
    /// delegation's unspent propagation inclusion covers the latency in
    /// flight.
    function testControlTwoLevelsSurviveWorstLatenciesWithoutReserve() public {
        uint64 allowance = T + 3 * G;
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, allowance));
        uint256 start = block.number;

        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);

        join(root, sRoot, SYBIL);
        rollTo(start + G - 1);
        join(root, hRoot, HONEST);
        // Sybil burns its own clock so the envelope is the honest remainder.
        rollBy(allowance - 1);
        advance(root, sRoot, hRoot);
        rollBy(G - 1);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, sRoot, hRoot);
        assertEq(allowanceOf(root, hRoot.root()), allowance - (G - 1));

        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        join(child, sChild, SYBIL);
        rollBy(T + G - 1);
        join(child, hChild, HONEST);
        advance(child, sChild, hChild);
        rollBy(G - 1);
        uint256 d = sealLeaf(child, sChild, hChild);
        rollBy(G - 1);
        prove(child, sChild, hChild, hChild, d);
        assertEq(allowanceOf(child, hChild.root()), G + 2, "child margin");
        if (vm.getBlockNumber() < closureOf(child)) {
            rollTo(closureOf(child));
        }
        rollBy(G - 1);
        propagate(root, child, hRoot);
        assertEq(allowanceOf(root, hRoot.root()), allowance - (G - 1));
        if (vm.getBlockNumber() < closureOf(root)) {
            rollTo(closureOf(root));
        }
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(hRoot.root()));
    }
}
