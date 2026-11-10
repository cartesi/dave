// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {RollupsTest} from "cartesi-rollups-contracts-3.0.0/test/util/RollupsTest.sol";

import {Machine} from "prt-contracts/types/Machine.sol";

import {IDaveConsensus} from "src/IDaveConsensus.sol";

import {DaveConsensusLifecycleHandler, DaveConsensusLifecycleVocabulary} from "./DaveConsensusLifecycleHandler.sol";

/// @notice `acceptStagedTournamentResult` with nothing staged reverts with
/// `TournamentResultNotStaged`, whatever else is true of the epoch: a
/// finished root, a failed root, every sentry's vote, a long-elapsed period,
/// a refused staging attempt, or a previous epoch's settlement.
/// @dev The handler only drives the lifecycle here; the calls under test go
/// to the consensus directly. These tests do not cover the staged cases,
/// which the lifecycle suites own.
contract DaveConsensusUnstagedAcceptanceTest is RollupsTest, DaveConsensusLifecycleVocabulary {
    uint256 internal constant PERIOD = 6;

    DaveConsensusLifecycleHandler internal handler;
    IDaveConsensus internal consensus;

    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(3, PERIOD);
        consensus = handler.consensus();
    }

    function testFreshEpochHasNothingToAccept() public {
        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(0);
    }

    function testFinishedRootIsNotAcceptedUntilItIsStaged() public {
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE + 1000);
        (bool isFinished, bool isFailed,,,,) = consensus.canStageTournamentResult();
        assertTrue(isFinished);
        assertFalse(isFailed);

        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(0);

        // The period runs from staging, not from the root's result.
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        vm.expectRevert(abi.encodeWithSelector(IDaveConsensus.ClaimStagingPeriodNotOverYet.selector, 0, PERIOD));
        consensus.acceptStagedTournamentResult(0);
    }

    function testEverySentryVoteDoesNotReplaceStaging() public {
        bytes32 state = handler.stateOf(SETTLING_ONE);
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE + PERIOD);
        for (uint256 slot = 1; slot <= 3; ++slot) {
            handler.claimAs(handler.sentryAt(slot), 0, state);
        }
        assertEq(consensus.getSentryClaimCount(0, Machine.Hash.wrap(state)), 3);

        address sentry = handler.sentryAt(1);
        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        vm.prank(sentry);
        consensus.acceptStagedTournamentResult(0);
    }

    function testRefusedStagingLeavesNothingToAccept() public {
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, ALTERED_OUTPUTS_ROOT);
        handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
        assertEq(handler.performed(IDaveConsensus.stageTournamentResult.selector), 0);

        handler.elapseBy(PERIOD);
        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(0);
    }

    function testRootWithoutAWinnerHasNothingToAccept() public {
        handler.elapseBy(ROOT_ALLOWANCE + PERIOD);
        (bool isFinished, bool isFailed,,,,) = consensus.canStageTournamentResult();
        assertTrue(isFinished);
        assertTrue(isFailed);

        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(0);
    }

    function testEverySettlementLeavesTheNextEpochUnstaged() public {
        for (uint256 settled; settled < 3; ++settled) {
            handler.settleEpochWith(settled % 2 == 0 ? SETTLING_ONE : SETTLING_TWO);

            // In the acceptance block itself, with the old period elapsed.
            vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
            consensus.acceptStagedTournamentResult(settled + 1);
            vm.expectRevert(abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, settled, settled + 1));
            consensus.acceptStagedTournamentResult(settled);

            (bool isStaged, bool agreed, bool periodOver,,,) = consensus.canAcceptStagedTournamentResult();
            assertFalse(isStaged);
            assertFalse(agreed);
            assertFalse(periodOver);
            handler.assertModel();
        }
    }

    function testEpochNumberIsCheckedBeforeStaging() public {
        vm.expectRevert(abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, 1, 0));
        consensus.acceptStagedTournamentResult(1);
    }

    function testForeclosureIsCheckedBeforeStaging() public {
        handler.forecloseAs(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(IApplicationChecker.ApplicationForeclosed.selector, address(handler.app()))
        );
        consensus.acceptStagedTournamentResult(0);
    }

    function testZeroPeriodWithoutSentriesStillNeedsStaging() public {
        handler = new DaveConsensusLifecycleHandler(0, 0);
        consensus = handler.consensus();
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);

        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(0);

        // Staged and accepted in one block, and unstaged again at once.
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        assertEq(handler.performed(IDaveConsensus.acceptStagedTournamentResult.selector), 1);
        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        consensus.acceptStagedTournamentResult(1);
    }

    function testFuzzNoCallerOrBlockAcceptsAnUnstagedEpoch(address caller, uint32 blocks) public {
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(uint256(ROOT_ALLOWANCE) + blocks);

        vm.expectRevert(IDaveConsensus.TournamentResultNotStaged.selector);
        vm.prank(caller);
        consensus.acceptStagedTournamentResult(0);
    }
}

/// @notice `provideMerkleRootOfInput` inside the sealed span accepts the
/// InputBox's bytes alone: anything else reverts with `InputHashMismatch`
/// naming the hash of what was offered and the hash on record, and the right
/// bytes return the root of their own tree. At or past the span the answer is
/// the zero padding, whatever the bytes.
/// @dev Three inputs are sealed in epoch one and a fourth is pending. The
/// expected roots come from the handler's own level-by-level fold. An index
/// whose position does not fit uint256 is only shown never to bind: the
/// consensus reverts there, where the padding rule would answer zero.
contract DaveConsensusInputBindingTest is RollupsTest, DaveConsensusLifecycleVocabulary {
    uint256 internal constant SEALED = 3;

    DaveConsensusLifecycleHandler internal handler;
    IDaveConsensus internal consensus;
    IInputBox internal inputBox;
    address internal app;

    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(0, 0);
        consensus = handler.consensus();
        inputBox = handler.inputBox();
        app = address(handler.app());

        // A short payload, an empty one, and one of several blocks.
        handler.addInputFrom(BYSTANDER, "one block");
        handler.addInputFrom(MANAGER, "");
        handler.addInputFrom(BYSTANDER, bytes.concat(keccak256("a"), keccak256("b"), keccak256("c"), hex"0d"));
        handler.settleEpochWith(SETTLING_ONE);
        handler.addInputFrom(BYSTANDER, "pending");

        (uint256 epochNumber, uint256 lower, uint256 upper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 1);
        assertEq(lower, 0);
        assertEq(upper, SEALED);
    }

    function testOtherBytesForASealedInputRevertWithBothHashes() public {
        bytes memory other = "not the input";
        for (uint256 i; i < SEALED; ++i) {
            bytes32 recorded = inputBox.getInputHash(app, i);
            assertEq(recorded, keccak256(handler.inputAt(i)));
            vm.expectRevert(
                abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(other), recorded)
            );
            consensus.provideMerkleRootOfInput(i, other);
        }
    }

    function testBytesOfAnotherSealedInputAreRefused() public {
        for (uint256 i; i < SEALED; ++i) {
            bytes memory neighbor = handler.inputAt((i + 1) % SEALED);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDaveConsensus.InputHashMismatch.selector, keccak256(neighbor), keccak256(handler.inputAt(i))
                )
            );
            consensus.provideMerkleRootOfInput(i, neighbor);
        }
    }

    function testOneByteMoreLessOrDifferentIsRefused() public {
        for (uint256 i; i < SEALED; ++i) {
            bytes memory input = handler.inputAt(i);
            bytes32 recorded = keccak256(input);

            bytes memory longer = bytes.concat(input, hex"00");
            vm.expectRevert(
                abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(longer), recorded)
            );
            consensus.provideMerkleRootOfInput(i, longer);

            bytes memory shorter = new bytes(input.length - 1);
            for (uint256 j; j < shorter.length; ++j) {
                shorter[j] = input[j];
            }
            vm.expectRevert(
                abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(shorter), recorded)
            );
            consensus.provideMerkleRootOfInput(i, shorter);

            uint256[3] memory positions = [uint256(0), input.length / 2, input.length - 1];
            for (uint256 j; j < positions.length; ++j) {
                bytes memory flipped = handler.inputAt(i);
                flipped[positions[j]] ^= 0x01;
                vm.expectRevert(
                    abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(flipped), recorded)
                );
                consensus.provideMerkleRootOfInput(i, flipped);
            }
        }
    }

    function testNoBytesForASealedInputAreRefused() public {
        for (uint256 i; i < SEALED; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDaveConsensus.InputHashMismatch.selector, keccak256(""), keccak256(handler.inputAt(i))
                )
            );
            consensus.provideMerkleRootOfInput(i, "");
        }
    }

    function testRightBytesReturnTheRootOfTheirOwnTree() public view {
        bytes32[] memory roots = new bytes32[](SEALED);
        for (uint256 i; i < SEALED; ++i) {
            bytes memory input = handler.inputAt(i);
            roots[i] = consensus.provideMerkleRootOfInput(i, input);
            assertEq(roots[i], handler.merkleRootOf(input));
            assertNotEq(roots[i], bytes32(0));
            for (uint256 j; j < i; ++j) {
                assertNotEq(roots[i], roots[j]);
            }
        }
    }

    function testIndexAtOrPastTheSpanIsPaddingWhateverTheBytes() public view {
        uint256[4] memory indices = [SEALED, SEALED + 1, EPOCH_INPUT_CAPACITY, type(uint256).max];
        for (uint256 i; i < indices.length; ++i) {
            // Nothing, noise, the pending input's own bytes, a sealed input's.
            assertEq(consensus.provideMerkleRootOfInput(indices[i], ""), bytes32(0));
            assertEq(consensus.provideMerkleRootOfInput(indices[i], "noise"), bytes32(0));
            assertEq(consensus.provideMerkleRootOfInput(indices[i], handler.inputAt(SEALED)), bytes32(0));
            assertEq(consensus.provideMerkleRootOfInput(indices[i], handler.inputAt(0)), bytes32(0));
        }
    }

    function testPendingInputBindsOnceItsEpochSeals() public {
        bytes memory pending = handler.inputAt(SEALED);
        handler.settleEpochWith(SETTLING_TWO);
        (, uint256 lower, uint256 upper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(lower, SEALED);
        assertEq(upper, SEALED + 1);

        // The index counts from the sealed epoch's lower bound.
        assertEq(consensus.provideMerkleRootOfInput(0, pending), handler.merkleRootOf(pending));
        bytes memory settled = handler.inputAt(0);
        vm.expectRevert(
            abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(settled), keccak256(pending))
        );
        consensus.provideMerkleRootOfInput(0, settled);
        assertEq(consensus.provideMerkleRootOfInput(1, pending), bytes32(0));
    }

    function testPositionPastUint256NeverBindsASettledInput() public {
        handler.settleEpochWith(SETTLING_TWO);
        (, uint256 lower,,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(lower, SEALED);

        for (uint256 settled; settled < SEALED; ++settled) {
            // The lower bound plus this index would wrap onto `settled`.
            uint256 index = type(uint256).max - SEALED + 1 + settled;
            try consensus.provideMerkleRootOfInput(index, handler.inputAt(settled)) returns (bytes32 root) {
                assertEq(root, bytes32(0));
            } catch {}
        }
    }

    function testFuzzAnyOtherBytesAreRefused(uint8 index, bytes calldata other) public {
        uint256 i = index % SEALED;
        bytes32 recorded = keccak256(handler.inputAt(i));
        vm.assume(keccak256(other) != recorded);

        vm.expectRevert(abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(other), recorded));
        consensus.provideMerkleRootOfInput(i, other);
    }
}
