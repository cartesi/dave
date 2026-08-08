// Copyright 2023 Cartesi Pte. Ltd.
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";

/**
 * @title FreezeBugTest
 * @notice Reproduces the PRT tournament liveness bug.
 *
 * Scenario:
 *  1. Player 0 joins; player 1 joins -> match created at the top level.
 *     Player 0's clock starts running (dangling commitment).
 *  2. Player 0 goes silent; its clock runs out after MAX_ALLOWANCE blocks.
 *  3. Player 1 is entitled to win by timeout, but waits too long — past its
 *     own remaining allowance. When it finally calls winMatchByTimeout, the
 *     contract tries to deduct player 0's (unbounded) overtime from player 1's
 *     clock. The saturating monus hits zero -> _setNewPaused reverts with
 *     "can't create clock with zero time". Because the overtime only grows,
 *     this revert is PERMANENT.
 *  4. The only remaining resolution path, eliminateMatchByTimeout, deletes the
 *     match with WinnerCommitment.NONE — both bonds destroyed, no winner.
 *  5. With the tournament closed and no dangling commitment, arbitrationResult
 *     reverts TournamentFailedNoWinner, so DaveConsensus.settle() can never
 *     succeed and the application (and its escrowed funds) are frozen forever.
 *
 * Clock values (from Util.sol):
 *   MAX_ALLOWANCE  = CENSORSHIP_TOLERANCE + COMMITMENT_EFFORT = 2400 + 300 = 2700
 *   MATCH_EFFORT   = 5 * 5 * 92 = 2300
 */
contract FreezeBugTest is Util {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable FACTORY;

    constructor() {
        (FACTORY,) = Util.instantiateTournamentFactory();
    }

    receive() external payable {}

    function testClockDeductionFreeze() public {
        // 1. Player 0 joins; player 1 joins -> match created, player 0's clock runs.
        ITournament topTournament = Util.initializePlayer0Tournament(FACTORY);
        Util.joinTournament(topTournament, 1);

        Match.Id memory matchId = Util.matchId(1, 0);
        uint64 topHeight = ArbitrationConstants.height(0); // 48

        // Read the live clock states to compute the exact trigger block.
        (Clock.State memory player0Clock,) =
            topTournament.getCommitment(playerNodes[0][topHeight]);
        (Clock.State memory player1Clock,) =
            topTournament.getCommitment(playerNodes[1][topHeight]);

        // 2. Fast-forward to the block where player 0 has timed out AND its
        //    overtime exceeds player 1's allowance — the permanent-revert point.
        //    player0.startInstant + player0.allowance              = p0 timeout
        //    + player1.allowance + 1                               = p0 overtime > p1 allowance
        uint256 targetBlock = Time.Instant.unwrap(player0Clock.startInstant)
            + Time.Duration.unwrap(player0Clock.allowance)
            + Time.Duration.unwrap(player1Clock.allowance) + 1;
        vm.roll(targetBlock);

        // Sanity: player 0 should be timed out, player 1 should still have time.
        (player0Clock,) = topTournament.getCommitment(playerNodes[0][topHeight]);
        (player1Clock,) = topTournament.getCommitment(playerNodes[1][topHeight]);
        assertTrue(!Clock.hasTimeLeft(player0Clock), "player 0 must be timed out");
        assertTrue(Clock.hasTimeLeft(player1Clock), "player 1 must still have time");

        // 3. Player 1 tries to win by timeout -> permanent revert.
        //    The deduction timeSinceTimeout(p0) > allowance(p1) saturates to 0.
        vm.prank(addrs[1]);
        vm.expectRevert("can't create clock with zero time");
        topTournament.winMatchByTimeout(
            matchId, playerNodes[1][topHeight - 1], playerNodes[1][topHeight - 1]
        );

        // 4. eliminateMatchByTimeout is the only remaining path. It deletes the
        //    match with WinnerCommitment.NONE — both bonds destroyed, no winner.
        topTournament.eliminateMatchByTimeout(matchId);

        // 5. With the tournament closed and no dangling commitment,
        //    arbitrationResult reverts -> settle() is impossible -> freeze.
        vm.expectRevert(ITournament.TournamentFailedNoWinner.selector);
        topTournament.arbitrationResult();
    }

    /**
     * @notice Demonstrates the bug is permanent: even calling winMatchByTimeout
     *         again after more time has passed still reverts (overtime only grows).
     */
    function testClockDeductionFreezeIsPermanent() public {
        ITournament topTournament = Util.initializePlayer0Tournament(FACTORY);
        Util.joinTournament(topTournament, 1);

        Match.Id memory matchId = Util.matchId(1, 0);
        uint64 topHeight = ArbitrationConstants.height(0);

        (Clock.State memory player0Clock,) =
            topTournament.getCommitment(playerNodes[0][topHeight]);
        (Clock.State memory player1Clock,) =
            topTournament.getCommitment(playerNodes[1][topHeight]);

        uint256 firstRevertBlock = Time.Instant.unwrap(player0Clock.startInstant)
            + Time.Duration.unwrap(player0Clock.allowance)
            + Time.Duration.unwrap(player1Clock.allowance) + 1;
        vm.roll(firstRevertBlock);

        // First attempt reverts.
        vm.prank(addrs[1]);
        vm.expectRevert("can't create clock with zero time");
        topTournament.winMatchByTimeout(
            matchId, playerNodes[1][topHeight - 1], playerNodes[1][topHeight - 1]
        );

        // Wait even more blocks — the overtime only grows.
        vm.roll(firstRevertBlock + 1000);

        // Still reverts. The condition can never recover.
        vm.prank(addrs[1]);
        vm.expectRevert("can't create clock with zero time");
        topTournament.winMatchByTimeout(
            matchId, playerNodes[1][topHeight - 1], playerNodes[1][topHeight - 1]
        );
    }
}
