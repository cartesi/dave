// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {
    BoundedOneLevelDelayModel
} from "../fixtures/BoundedOneLevelDelayModel.sol";
import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {
    SmallSingleLevelTournamentFactory
} from "../fixtures/SmallSingleLevelTournament.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;
using TournamentInspector for InspectableTournament;

/// @dev Exhaustive finite-state evidence for the clock-only delay model.
/// These exact maxima apply only to the stated discrete domain and its prompt
/// timeout-cleanup assumption. Proof winners are independently scheduler-chosen,
/// so these are maxima of a clock-only upper envelope, not an exact
/// one-honest adversarial strategy. They are deliberately not claimed as a
/// formula for arbitrary populations or parameters.
/// Inheritance keeps the search in the test call frame, where paused gas
/// metering is effective. An external solver call retains a finite gas-forwarding
/// cap even though model SSTOREs are not production work.
contract BoundedOneLevelDelayTest is Test, BoundedOneLevelDelayModel {
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Duration;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant PRODUCTION_TRACE_COMPLETION = 19;
    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    address internal constant CLAIMER_THREE = address(0xca11);

    function testExhaustiveHeightOneFiniteMaxima() public {
        // Exhaustion is the subject of this test; its fixture SSTOREs are not
        // measurements of production gas and can exceed Foundry's block cap.
        vm.pauseGasMetering();
        for (uint8 responseBudget; responseBudget <= 2; ++responseBudget) {
            for (uint8 allowance = 1; allowance <= 4; ++allowance) {
                for (uint8 claims = 6; claims != 0; --claims) {
                    BoundedOneLevelDelayModel.Configuration memory config =
                        _config(claims, allowance, responseBudget, 1);
                    (uint8 completion,) = solve(config);
                    assertEq(
                        completion,
                        _heightOneExpected(claims, allowance, responseBudget)
                    );
                }
            }
        }
    }

    function testExhaustiveHeightTwoFiniteMaxima() public {
        vm.pauseGasMetering();
        _assertAlternatingBisectionMaxima(2);
    }

    function testExhaustiveHeightThreeFiniteMaxima() public {
        vm.pauseGasMetering();
        _assertAlternatingBisectionMaxima(3);
    }

    function testReconstructsExplicitMaximumWitness() public {
        BoundedOneLevelDelayModel.Configuration memory config =
            _config(3, 4, 2, 3);
        (uint8 completion, uint256 statesVisited) = solve(config);
        assertEq(completion, PRODUCTION_TRACE_COMPLETION);
        assertGt(statesVisited, 0);

        BoundedOneLevelDelayModel.Witness memory schedule = witness(config);
        uint8[10] memory expectedTimes =
            [uint8(0), 0, 0, 2, 4, 8, 10, 13, 16, 19];
        BoundedOneLevelDelayModel.ActionKind[10] memory expectedKinds = [
            BoundedOneLevelDelayModel.ActionKind.JOIN,
            BoundedOneLevelDelayModel.ActionKind.JOIN,
            BoundedOneLevelDelayModel.ActionKind.JOIN,
            BoundedOneLevelDelayModel.ActionKind.RESPOND,
            BoundedOneLevelDelayModel.ActionKind.RESPOND,
            BoundedOneLevelDelayModel.ActionKind.TIMEOUT,
            BoundedOneLevelDelayModel.ActionKind.RESPOND,
            BoundedOneLevelDelayModel.ActionKind.RESPOND,
            BoundedOneLevelDelayModel.ActionKind.RESPOND,
            BoundedOneLevelDelayModel.ActionKind.TIMEOUT
        ];

        uint256 materialAction;
        for (uint256 i; i < schedule.actions.length; ++i) {
            BoundedOneLevelDelayModel.ActionKind kind =
                actionKind(schedule.actions[i]);
            if (kind == BoundedOneLevelDelayModel.ActionKind.WAIT) continue;

            BoundedOneLevelDelayModel.StateView memory before_ =
                inspectState(schedule.states[i]);
            assertEq(before_.current, expectedTimes[materialAction]);
            assertEq(uint8(kind), uint8(expectedKinds[materialAction]));
            ++materialAction;
        }
        assertEq(materialAction, expectedTimes.length);

        BoundedOneLevelDelayModel.StateView memory final_ =
            inspectState(schedule.states[schedule.states.length - 1]);
        assertEq(final_.current, PRODUCTION_TRACE_COMPLETION);
        assertEq(final_.unjoined, 0);
        assertEq(final_.danglingAllowance, 0);
        assertEq(final_.matchCount, 0);

        // The final response starts an equal three-block leaf race. The last
        // timeout therefore eliminates both commitments at relative block 19.
        uint256 finalResponse;
        for (uint256 i; i < schedule.actions.length; ++i) {
            if (
                actionKind(schedule.actions[i])
                    == BoundedOneLevelDelayModel.ActionKind.RESPOND
            ) {
                finalResponse = i;
            }
        }
        BoundedOneLevelDelayModel.StateView memory sealedState =
            inspectState(schedule.states[finalResponse + 1]);
        assertEq(sealedState.current, 16);
        assertEq(sealedState.matchCount, 1);
        BoundedOneLevelDelayModel.MatchView memory sealedMatch =
            inspectMatch(schedule.states[finalResponse + 1], 0);
        assertEq(sealedMatch.responsesRemaining, 0);
        assertEq(sealedMatch.allowanceOne, 3);
        assertEq(sealedMatch.allowanceTwo, 3);
        assertEq(sealedMatch.startInstant, 16);
    }

    function testMaximumWitnessUsesPreTimeoutProof() public {
        BoundedOneLevelDelayModel.Configuration memory config =
            _config(6, 1, 0, 1);
        (uint8 completion,) = solve(config);
        assertEq(completion, 3);

        BoundedOneLevelDelayModel.Witness memory schedule = witness(config);
        bool foundProof;
        for (uint256 i; i < schedule.actions.length; ++i) {
            BoundedOneLevelDelayModel.ActionKind kind =
                actionKind(schedule.actions[i]);
            if (
                kind != BoundedOneLevelDelayModel.ActionKind.PROVE_LOW
                    && kind != BoundedOneLevelDelayModel.ActionKind.PROVE_HIGH
            ) {
                continue;
            }

            foundProof = true;
            BoundedOneLevelDelayModel.StateView memory before_ =
                inspectState(schedule.states[i]);
            BoundedOneLevelDelayModel.StateView memory after_ =
                inspectState(schedule.states[i + 1]);
            assertEq(before_.current, 0);
            assertEq(before_.matchCount, 3);
            assertEq(before_.danglingAllowance, 0);
            assertEq(after_.matchCount, 2);
            assertEq(after_.danglingAllowance, 1);
            break;
        }
        assertTrue(foundProof);
    }

    function testClockModelMaximumWitnessExecutesAgainstTournament() public {
        BoundedOneLevelDelayModel.Configuration memory config =
            _config(3, 4, 2, 3);
        (uint8 modelCompletion,) = solve(config);
        assertEq(modelCompletion, PRODUCTION_TRACE_COMPLETION);

        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);
        vm.deal(CLAIMER_ONE, 100 ether);
        vm.deal(CLAIMER_TWO, 100 ether);
        vm.deal(CLAIMER_THREE, 100 ether);

        SmallSingleLevelTournamentFactory factory = new SmallSingleLevelTournamentFactory(
            Time.Duration.wrap(2), Time.Duration.wrap(4)
        );
        InspectableTournament tournament = InspectableTournament(
            address(
                factory.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), 3);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), 3);
        SmallFullTree.Data memory three =
            SmallFullTree.build(bytes32(uint256(3)), 3);

        _join(tournament, one, CLAIMER_ONE);
        _join(tournament, two, CLAIMER_TWO);
        _join(tournament, three, CLAIMER_THREE);
        Match.Id memory first = Match.Id(one.root(), two.root());

        vm.roll(START_BLOCK + 2);
        _advance(tournament, first, one, 3);
        vm.roll(START_BLOCK + 4);
        _advance(tournament, first, two, 2);

        vm.roll(START_BLOCK + 8);
        assertTrue(tournament.canWinMatchByTimeout(first));
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(3, 0);
        tournament.winMatchByTimeout(first, twoLeft, twoRight);

        Match.Id memory repaired = Match.Id(three.root(), two.root());
        assertTrue(tournament.getMatch(repaired.hashFromId()).exists());
        vm.roll(START_BLOCK + 10);
        _advance(tournament, repaired, three, 3);
        vm.roll(START_BLOCK + 13);
        _advance(tournament, repaired, two, 2);

        vm.roll(START_BLOCK + 16);
        (Tree.Node finalLeft, Tree.Node finalRight) = three.children(1, 0);
        tournament.sealLeafMatch(
            repaired, finalLeft, finalRight, INITIAL_STATE, new bytes32[](0)
        );
        _assertClock(tournament, three.root(), true, 3, START_BLOCK + 16);
        _assertClock(tournament, two.root(), true, 3, START_BLOCK + 16);

        vm.roll(START_BLOCK + PRODUCTION_TRACE_COMPLETION);
        assertFalse(tournament.canWinMatchByTimeout(repaired));
        // This cross-check validates clock mechanics, not an honest-validator
        // outcome: the model's final equal race eliminates both commitments.
        tournament.eliminateMatchByTimeout(repaired);

        (Tree.Node dangling, uint256 activeMatches, Time.Instant deletedAt) =
            tournament.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(activeMatches, 0);
        assertEq(
            Time.Instant.unwrap(deletedAt),
            START_BLOCK + PRODUCTION_TRACE_COMPLETION
        );
        assertTrue(tournament.isClosed());
        assertTrue(tournament.isFinished());
        (bool known, Time.Instant finishedAt) = tournament.timeFinished();
        assertTrue(known);
        assertEq(Time.Instant.unwrap(finishedAt), START_BLOCK + modelCompletion);
        assertEq(tournament.getCommitmentJoinedCount(), 3);
        assertEq(tournament.getMatchCreatedCount(), 2);
        assertEq(tournament.getMatchAdvancedCount(), 4);
        assertEq(tournament.getMatchDeletedCount(), 2);
    }

    function _assertAlternatingBisectionMaxima(uint8 height) private {
        for (uint8 responseBudget; responseBudget <= 2; ++responseBudget) {
            for (uint8 allowance = 1; allowance <= 4; ++allowance) {
                for (uint8 claims = 6; claims != 0; --claims) {
                    BoundedOneLevelDelayModel.Configuration memory config =
                        _config(claims, allowance, responseBudget, height);
                    (uint8 completion,) = solve(config);
                    assertEq(
                        completion,
                        _heightTwoOrThreeExpectedWithinDomain(
                            claims, allowance, responseBudget, height
                        )
                    );
                }
            }
        }
    }

    function _heightTwoOrThreeExpectedWithinDomain(
        uint8 claims,
        uint8 allowance,
        uint8 responseBudget,
        uint8 height
    ) private pure returns (uint8) {
        // This is a compact golden table for the 144 cells enumerated above,
        // not an induction claim outside the bounded domain.
        if (claims == 1) return allowance;

        uint8 cappedBudget =
            responseBudget < allowance ? responseBudget : allowance - 1;
        uint8 discounts = (height - 1) * cappedBudget;
        uint8 firstPair = 2 * allowance - 1 + discounts;
        uint8 additionalPair = allowance + discounts;
        uint8 sequentialPairs = (claims + 1) / 2;
        return firstPair + (sequentialPairs - 1) * additionalPair;
    }

    function _heightOneExpected(
        uint8 claims,
        uint8 allowance,
        uint8 responseBudget
    ) private pure returns (uint8) {
        // Rows are grouped by response budget, then allowance. Height one has
        // a distinct leaf-race topology, so the finite results stay explicit
        // instead of being generalized from a visual pattern.
        uint8[6][12] memory maxima = [
            // Response budget 0, allowances 1 through 4.
            [uint8(1), 1, 2, 2, 3, 3],
            [uint8(2), 3, 4, 5, 6, 6],
            [uint8(3), 5, 6, 8, 9, 9],
            [uint8(4), 7, 8, 11, 12, 12],
            // Response budget 1, allowances 1 through 4.
            [uint8(1), 1, 2, 2, 3, 3],
            [uint8(2), 3, 5, 5, 7, 7],
            [uint8(3), 5, 7, 8, 10, 10],
            [uint8(4), 7, 10, 11, 14, 14],
            // Response budget 2, allowances 1 through 4.
            [uint8(1), 1, 2, 2, 3, 3],
            [uint8(2), 3, 5, 5, 7, 7],
            [uint8(3), 5, 8, 9, 11, 11],
            [uint8(4), 7, 10, 12, 14, 14]
        ];
        uint256 row = uint256(responseBudget) * 4 + allowance - 1;
        return maxima[row][claims - 1];
    }

    function _config(
        uint8 claims,
        uint8 allowance,
        uint8 responseBudget,
        uint8 height
    ) private pure returns (BoundedOneLevelDelayModel.Configuration memory) {
        return BoundedOneLevelDelayModel.Configuration({
            claims: claims,
            allowance: allowance,
            responseBudget: responseBudget,
            height: height
        });
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private {
        (Tree.Node left, Tree.Node right) = tree.children(3, 0);
        vm.prank(claimer);
        tournament.joinTournament{value: tournament.bondValue()}(
            tree.finalState(), tree.finalProof(), left, right
        );
    }

    function _advance(
        InspectableTournament tournament,
        Match.Id memory matchId,
        SmallFullTree.Data memory revealing,
        uint64 height
    ) private {
        (Tree.Node left, Tree.Node right) = revealing.children(height, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) =
            revealing.children(height - 1, 0);
        tournament.advanceMatch(matchId, left, right, nextLeft, nextRight);
    }

    function _assertClock(
        InspectableTournament tournament,
        Tree.Node root,
        bool expectedRunning,
        uint64 expectedAllowance,
        uint64 expectedStart
    ) private view {
        (Clock.State memory clock,) = tournament.getCommitment(root);
        assertTrue(clock.isInitialized());
        assertEq(clock.isRunning(), expectedRunning);
        assertEq(Time.Duration.unwrap(clock.allowance), expectedAllowance);
        assertEq(Time.Instant.unwrap(clock.startInstant), expectedStart);
    }
}
