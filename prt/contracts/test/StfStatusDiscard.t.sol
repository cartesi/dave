// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";
import {UArchStep} from "step/src/UArchStep.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";

/// @dev STF-TODO-001 (docs/reviews/2026-07-21-prt-dispute-game/REVIEW.md):
/// CartesiStateTransition discards UArchStep.step's status. Candidate: the
/// discard lets a prover obtain, at some shape, a root other than the one the
/// honest builder emits (computation-hash.md, ruler.rs step_until).
///
/// Refutation pinned here without FFI, over a synthetic sparse state:
/// - The status is a function of the uarch (cycle, halt) words before and
///   after the step; the root already carries every write. Both non-Success
///   statuses occur after an executed, root-changing step (an ECALL halt, or
///   the step that reaches UARCH_CYCLE_MAX), so the status cannot stand in
///   for "identity" and returning the access-log root is the only sound
///   reading.
/// - The fixed points (halt set, or cycle at UARCH_CYCLE_MAX) read and never
///   write, so they are identities at every shape; the closing shape then
///   resets, substituting the recorded root only on RX_REJECTED.
/// - The adapter applies its shape's composition whatever the status, as
///   the ruler does: ustep (identity when halted), then ureset at a closing.
///
/// Sparse model: an absent node is bytes32(0) and a present node hashes its
/// two children. The verifier recomputes paths only, so any such tree is a
/// valid witness; expected roots come from the model, not from the adapter.
contract StfStatusDiscardTest is Test {
    uint8 constant TOP = Memory.LOG2_MAX_SIZE;

    uint64 constant HALT = EmulatorConstants.UARCH_HALT_ADDRESS;
    uint64 constant CYCLE = EmulatorConstants.UARCH_CYCLE_ADDRESS;
    uint64 constant PC = EmulatorConstants.UARCH_PC_ADDRESS;
    uint64 constant X0 = EmulatorConstants.UARCH_X0_ADDRESS;
    uint64 constant IFLAGS_Y = EmulatorConstants.IFLAGS_Y_ADDRESS;
    uint64 constant TOHOST = EmulatorConstants.HTIF_TOHOST_ADDRESS;
    uint64 constant REVERT_SLOT = EmulatorConstants.REVERT_ROOT_HASH_ADDRESS;
    uint64 constant MAX = EmulatorConstants.UARCH_CYCLE_MAX;
    uint64 constant UARCH_RAM = EmulatorConstants.UARCH_RAM_START_ADDRESS;
    uint64 constant BIG_RAM = 0x80000000;

    // The uarch state region as a node: 2^22 bytes at 0x400000.
    uint8 constant UARCH_LEVEL =
        EmulatorConstants.UARCH_STATE_LOG2_SIZE - Memory.LOG2_LEAF;
    uint64 constant UARCH_INDEX = EmulatorConstants.UARCH_STATE_START_ADDRESS
        >> EmulatorConstants.UARCH_STATE_LOG2_SIZE;

    uint32 constant ECALL = 0x00000073;
    uint32 constant SD_X1_0_X2 = 0x00113023; // sd x1, 0(x2)

    uint256 constant U = 1 << 20;
    uint256 constant PLAIN = U + 7;
    uint256 constant NEAR_CLOSE = 3 * U + (U - 2);
    uint256 constant CLOSE = 3 * U + (U - 1);
    uint256 constant OPEN = 1 << 68;

    IDataProvider constant PROVIDER = IDataProvider(address(0x123));

    CartesiStateTransition stf;

    mapping(uint256 => bytes32) nodes;
    mapping(uint64 => bytes32) leaves;
    bytes log_;

    function setUp() public {
        stf = new CartesiStateTransition();
    }

    // Fixed points: read-only at every shape.

    function testRefutedHaltedFixedPointIsIdentityAtPlainStep() public {
        _uarch(1, 42, UARCH_RAM);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);

        assertEq(
            uint8(_status(pre)), uint8(UArchStep.UArchStepStatus.UArchHalted)
        );
        assertEq(stf.transitionState(pre, PLAIN, log_, PROVIDER), pre);
    }

    function testRefutedHaltedFixedPointIsIdentityAtOpeningWithoutInput()
        public
    {
        _uarch(1, 42, UARCH_RAM);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _mockRoot(bytes32(0));

        assertEq(
            stf.transitionState(
                pre, OPEN, abi.encodePacked(uint64(0), log_), PROVIDER
            ),
            pre
        );
    }

    /// An input to a machine with no pending yield is a CMIO no-op, and a
    /// halted uarch then steps as identity.
    function testRefutedCmioNoOpThenHaltedStepIsIdentityAtOpening() public {
        _uarch(1, 42, UARCH_RAM);
        _setWord(IFLAGS_Y, 0);
        bytes32 pre = _root();
        _read(IFLAGS_Y);
        _read(CYCLE);
        _read(HALT);
        bytes memory input = hex"c0ffee";
        _mockRoot(keccak256("input root"));

        assertEq(
            stf.transitionState(
                pre,
                OPEN,
                abi.encodePacked(uint64(input.length), input, log_),
                PROVIDER
            ),
            pre
        );
    }

    // Executed steps that report a non-Success status change the root.

    function testRefutedExecutedHaltReportsHaltedAndChangesRoot() public {
        _uarch(0, 42, UARCH_RAM);
        _setInsn(UARCH_RAM, ECALL);
        _setWord(_x(17), EmulatorConstants.UARCH_ECALL_FN_HALT);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _read(PC);
        _read(UARCH_RAM);
        _read(_x(17));
        _write(HALT, 1);
        _write(CYCLE, 43);
        // Below the limit, a halting ECALL re-reads the halt flag.
        _read(HALT);
        bytes32 post = _root();

        assertEq(
            uint8(_status(pre)), uint8(UArchStep.UArchStepStatus.UArchHalted)
        );
        assertNotEq(post, pre);
        assertEq(stf.transitionState(pre, PLAIN, log_, PROVIDER), post);
    }

    /// The tempting fix for STF-TODO-001, returning the pre-state on any
    /// non-Success status, would reject the honest post-state of a halting
    /// ECALL, which the builder's run_uarch executes.
    function testRefutedStatusGatedAdapterWouldRejectExecutedHalt() public {
        _uarch(0, 42, UARCH_RAM);
        _setInsn(UARCH_RAM, ECALL);
        _setWord(_x(17), EmulatorConstants.UARCH_ECALL_FN_HALT);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _read(PC);
        _read(UARCH_RAM);
        _read(_x(17));
        _write(HALT, 1);
        _write(CYCLE, 43);
        _read(HALT);
        bytes32 post = _root();

        StatusGatedPlainStep gated = new StatusGatedPlainStep();
        assertEq(gated.transitionState(pre, log_), pre);
        assertEq(stf.transitionState(pre, PLAIN, log_, PROVIDER), post);
    }

    /// The halting ECALL as the 2^20 - 1st instruction: overflow takes
    /// precedence in the status, the halt write stays in the root. Off the
    /// honest path with the pristine ROM (the heaviest instruction measured
    /// on v0.21, sfence.vma, takes 17,595 usteps); pinned because the v0.21
    /// CLI throws here (computation-hash.md).
    function testRefutedHaltAtCycleMaxReportsOverflowAndChangesRoot() public {
        _uarch(0, MAX - 1, UARCH_RAM);
        _setInsn(UARCH_RAM, ECALL);
        _setWord(_x(17), EmulatorConstants.UARCH_ECALL_FN_HALT);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _read(PC);
        _read(UARCH_RAM);
        _read(_x(17));
        _write(HALT, 1);
        _write(CYCLE, MAX);
        bytes32 post = _root();

        assertEq(
            uint8(_status(pre)),
            uint8(UArchStep.UArchStepStatus.UArchCycleOverflow)
        );
        assertNotEq(post, pre);
        assertEq(stf.transitionState(pre, NEAR_CLOSE, log_, PROVIDER), post);
    }

    /// An unhalted uarch reaching UARCH_CYCLE_MAX at the last ordinary slot
    /// reports overflow after a store into the big machine, which the
    /// closing reset then keeps.
    function testRefutedOverflowAfterStoreKeepsStoreThroughClosing() public {
        _uarch(0, MAX - 1, UARCH_RAM);
        _setInsn(UARCH_RAM, SD_X1_0_X2);
        _setWord(_x(1), 0x1234);
        _setWord(_x(2), BIG_RAM);
        _setWord(BIG_RAM, 0);
        _setWord(IFLAGS_Y, 0);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _read(PC);
        _read(UARCH_RAM);
        _read(_x(2));
        _read(_x(1));
        _write(BIG_RAM, 0x1234);
        _write(PC, UARCH_RAM + 4);
        _write(CYCLE, MAX);
        bytes32 stepped = _root();

        assertEq(
            uint8(_status(pre)),
            uint8(UArchStep.UArchStepStatus.UArchCycleOverflow)
        );
        assertEq(stf.transitionState(pre, NEAR_CLOSE, log_, PROVIDER), stepped);

        // Closing: the overflow fixed point reads the cycle only, then reset.
        delete log_;
        _read(CYCLE);
        _writeRegion(
            UARCH_LEVEL,
            UARCH_INDEX,
            EmulatorConstants.UARCH_PRISTINE_STATE_HASH
        );
        _read(IFLAGS_Y);
        bytes32 closed = _root();

        assertEq(stf.transitionState(stepped, CLOSE, log_, PROVIDER), closed);
        assertEq(_word(BIG_RAM), 0x1234);
    }

    // Closing shape: the step's status never gates the reset.

    function testRefutedClosingAfterHaltAtCycleMaxIsIdentityThenReset() public {
        _uarch(1, MAX, UARCH_RAM);
        _setWord(IFLAGS_Y, 0);
        bytes32 pre = _root();
        _read(CYCLE);
        _writeRegion(
            UARCH_LEVEL,
            UARCH_INDEX,
            EmulatorConstants.UARCH_PRISTINE_STATE_HASH
        );
        _read(IFLAGS_Y);
        bytes32 post = _root();

        assertNotEq(post, pre);
        assertEq(stf.transitionState(pre, CLOSE, log_, PROVIDER), post);
    }

    function testRefutedHaltedClosingOnRejectionReturnsRecordedRoot() public {
        _assertRejectedClosing(1, 50);
    }

    function testRefutedOverflowClosingOnRejectionReturnsRecordedRoot() public {
        _assertRejectedClosing(0, MAX);
    }

    function testRefutedHaltedClosingOnAcceptedYieldOnlyResets() public {
        _uarch(1, 50, UARCH_RAM);
        _setWord(IFLAGS_Y, 1);
        _setWord(
            TOHOST,
            _manualYield(EmulatorConstants.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED)
        );
        _setLeaf(REVERT_SLOT >> Memory.LOG2_LEAF, keccak256("recorded root"));
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _writeRegion(
            UARCH_LEVEL,
            UARCH_INDEX,
            EmulatorConstants.UARCH_PRISTINE_STATE_HASH
        );
        _read(IFLAGS_Y);
        _read(TOHOST);
        bytes32 post = _root();

        assertEq(stf.transitionState(pre, CLOSE, log_, PROVIDER), post);
    }

    /// Off the honest path (a closing never sees a live uarch from a
    /// pristine opening), the closing still executes a Success step before
    /// the reset, as the ruler's closing slot does.
    function testRefutedClosingExecutesLiveStepBeforeReset() public {
        _uarch(0, 5, UARCH_RAM);
        _setInsn(UARCH_RAM, SD_X1_0_X2);
        _setWord(_x(1), 0x1234);
        _setWord(_x(2), BIG_RAM);
        _setWord(BIG_RAM, 0);
        _setWord(IFLAGS_Y, 0);
        bytes32 pre = _root();
        _read(CYCLE);
        _read(HALT);
        _read(PC);
        _read(UARCH_RAM);
        _read(_x(2));
        _read(_x(1));
        _write(BIG_RAM, 0x1234);
        _write(PC, UARCH_RAM + 4);
        _write(CYCLE, 6);
        uint256 stepEnd = log_.length;
        _writeRegion(
            UARCH_LEVEL,
            UARCH_INDEX,
            EmulatorConstants.UARCH_PRISTINE_STATE_HASH
        );
        _read(IFLAGS_Y);
        bytes32 post = _root();

        bytes memory stepOnly = new bytes(stepEnd);
        for (uint256 i; i < stepEnd; ++i) {
            stepOnly[i] = log_[i];
        }
        assertEq(
            uint8(_status(pre, stepOnly)),
            uint8(UArchStep.UArchStepStatus.Success)
        );
        assertEq(stf.transitionState(pre, CLOSE, log_, PROVIDER), post);
        assertEq(_word(BIG_RAM), 0x1234);
    }

    function _assertRejectedClosing(uint64 halt, uint64 cycle) private {
        bytes32 recorded = keccak256("recorded root");
        _uarch(halt, cycle, UARCH_RAM);
        _setWord(IFLAGS_Y, 1);
        _setWord(
            TOHOST,
            _manualYield(EmulatorConstants.HTIF_YIELD_MANUAL_REASON_RX_REJECTED)
        );
        _setLeaf(REVERT_SLOT >> Memory.LOG2_LEAF, recorded);
        bytes32 pre = _root();
        _read(CYCLE);
        if (cycle < MAX) {
            _read(HALT);
        }
        _writeRegion(
            UARCH_LEVEL,
            UARCH_INDEX,
            EmulatorConstants.UARCH_PRISTINE_STATE_HASH
        );
        _read(IFLAGS_Y);
        _read(TOHOST);
        _readRevertSlot();

        assertEq(stf.transitionState(pre, CLOSE, log_, PROVIDER), recorded);
    }

    // Model.

    function _status(bytes32 pre)
        private
        view
        returns (UArchStep.UArchStepStatus)
    {
        return _status(pre, log_);
    }

    function _status(bytes32 pre, bytes memory proof)
        private
        pure
        returns (UArchStep.UArchStepStatus)
    {
        return UArchStep.step(AccessLogs.Context(pre, Buffer.Context(proof, 0)));
    }

    function _mockRoot(bytes32 root) private {
        vm.mockCall(
            address(PROVIDER),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(root)
        );
    }

    function _manualYield(uint16 reason) private pure returns (uint64) {
        return (EmulatorConstants.HTIF_DEV_YIELD
                << EmulatorConstants.HTIF_DEV_SHIFT)
            | (EmulatorConstants.HTIF_YIELD_CMD_MANUAL
                << EmulatorConstants.HTIF_CMD_SHIFT)
            | (uint64(reason) << EmulatorConstants.HTIF_REASON_SHIFT);
    }

    function _uarch(uint64 halt, uint64 cycle, uint64 pc) private {
        _setWord(HALT, halt);
        _setWord(CYCLE, cycle);
        _setWord(PC, pc);
    }

    function _x(uint8 i) private pure returns (uint64) {
        return X0 + (uint64(i) << 3);
    }

    function _setInsn(uint64 paddr, uint32 insn) private {
        _setWord(paddr, insn);
    }

    function _key(uint256 level, uint256 index) private pure returns (uint256) {
        return (level << 64) | index;
    }

    function _root() private view returns (bytes32) {
        return nodes[_key(TOP, 0)];
    }

    function _setNode(uint8 level, uint64 index, bytes32 h) private {
        nodes[_key(level, index)] = h;
        for (uint8 l = level + 1; l <= TOP; ++l) {
            index >>= 1;
            nodes[_key(l, index)] = keccak256(
                abi.encodePacked(
                    nodes[_key(l - 1, 2 * uint256(index))],
                    nodes[_key(l - 1, 2 * uint256(index) + 1)]
                )
            );
        }
    }

    function _setLeaf(uint64 leafIndex, bytes32 data) private {
        leaves[leafIndex] = data;
        _setNode(0, leafIndex, keccak256(abi.encodePacked(data)));
    }

    function _word(uint64 paddr) private view returns (uint64) {
        bytes32 leaf = leaves[paddr >> Memory.LOG2_LEAF];
        return AccessLogs.machineWordToSolidityUint64(
            AccessLogs.getBytes8FromBytes32AtOffset(
                leaf, paddr & Memory.LEAF_MASK
            )
        );
    }

    function _setWord(uint64 paddr, uint64 value) private {
        uint64 leafIndex = paddr >> Memory.LOG2_LEAF;
        _setLeaf(
            leafIndex,
            AccessLogs.setBytes8ToBytes32AtOffset(
                AccessLogs.solidityUint64ToMachineWord(value),
                leaves[leafIndex],
                paddr & Memory.LEAF_MASK
            )
        );
    }

    function _siblings(uint8 level, uint64 index)
        private
        view
        returns (bytes memory out)
    {
        for (uint8 i = 0; level + i < TOP; ++i) {
            out = bytes.concat(out, nodes[_key(level + i, (index >> i) ^ 1)]);
        }
    }

    function _read(uint64 paddr) private {
        uint64 leafIndex = paddr >> Memory.LOG2_LEAF;
        log_ = bytes.concat(log_, leaves[leafIndex], _siblings(0, leafIndex));
    }

    function _write(uint64 paddr, uint64 value) private {
        _read(paddr);
        _setWord(paddr, value);
    }

    function _writeRegion(uint8 level, uint64 index, bytes32 h) private {
        log_ = bytes.concat(
            log_, nodes[_key(level, index)], _siblings(level, index)
        );
        _setNode(level, index, h);
    }

    function _readRevertSlot() private {
        uint64 leafIndex = REVERT_SLOT >> Memory.LOG2_LEAF;
        log_ = bytes.concat(
            log_,
            leaves[leafIndex],
            nodes[_key(0, leafIndex)],
            _siblings(0, leafIndex)
        );
    }
}

/// @dev Mutant of the adapter's plain shape that honors the status. Test-only.
contract StatusGatedPlainStep {
    function transitionState(bytes32 machineState, bytes calldata proofs)
        external
        pure
        returns (bytes32)
    {
        AccessLogs.Context memory a =
            AccessLogs.Context(machineState, Buffer.Context(proofs, 0));
        if (UArchStep.step(a) != UArchStep.UArchStepStatus.Success) {
            return machineState;
        }
        return a.currentRootHash;
    }
}
