// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.22;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/InputBox.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentParametersProvider} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {CartesiStateTransition} from "prt-contracts/state-transition/CartesiStateTransition.sol";
import {CmioStateTransition} from "prt-contracts/state-transition/CmioStateTransition.sol";
import {RiscVStateTransition} from "prt-contracts/state-transition/RiscVStateTransition.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import {Bond} from "prt-contracts/tournament/libs/Bond.sol";
import {Gas} from "prt-contracts/tournament/libs/Gas.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {TournamentParameters} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {DaveConsensus} from "src/DaveConsensus.sol";

library LeafGasGeometry {
    uint64 internal constant LEVELS = 2;
    uint64 internal constant ROOT_LOG2_STEP = 1;
    uint64 internal constant ROOT_HEIGHT = 1;
    uint64 internal constant LEAF_LOG2_STEP = 0;
    uint64 internal constant LEAF_HEIGHT = 1;
    uint64 internal constant RESPONSE_BUDGET = 300;
    uint64 internal constant MAX_ALLOWANCE = 1_000_000;
}

contract LeafGasParametersProvider is ITournamentParametersProvider {
    function tournamentParameters(uint64 level) external pure override returns (TournamentParameters memory) {
        require(level < LeafGasGeometry.LEVELS);
        return TournamentParameters({
            levels: LeafGasGeometry.LEVELS,
            log2step: level == 0 ? LeafGasGeometry.ROOT_LOG2_STEP : LeafGasGeometry.LEAF_LOG2_STEP,
            height: level == 0 ? LeafGasGeometry.ROOT_HEIGHT : LeafGasGeometry.LEAF_HEIGHT,
            responseBudget: Time.Duration.wrap(LeafGasGeometry.RESPONSE_BUDGET),
            maxAllowance: Time.Duration.wrap(LeafGasGeometry.MAX_ALLOWANCE)
        });
    }
}

contract LeafGasApplication {
    function isForeclosed() external pure returns (bool) {
        return false;
    }
}

abstract contract LeafTournamentGasFixture is Test {
    using Tree for Tree.Node;

    enum WinnerSide {
        ONE,
        TWO
    }

    struct ProofVector {
        Machine.Hash epochInitialState;
        Machine.Hash tournamentInitialState;
        Machine.Hash agreeState;
        Machine.Hash nextState;
        bytes proof;
    }

    struct Measurement {
        uint256 allocationUnits;
        uint256 completeCallGas;
        uint256 calldataBytes;
        uint256 zeroCalldataBytes;
        uint256 nonzeroCalldataBytes;
    }

    uint64 internal constant LEAF_LEVEL = 1;
    uint256 private constant INPUT_SPAN = 1 << 68;
    uint256 internal constant REPRESENTATIVE_PAYLOAD_SIZE = 4_096;
    uint256 internal constant MAX_PAYLOAD_SIZE = 65_216;
    uint256 internal constant MAX_ENCODED_INPUT_SIZE = 65_508;
    uint256 private constant FIRST_REJECTED_INPUT_SIZE = 65_540;
    uint256 private constant INPUT_MAX_SIZE = 65_536;
    uint256 private constant FFI_INPUT_CHUNK_BYTES = 16_384;

    bytes32 internal constant WRONG_STATE = bytes32(uint256(0xdead));
    bytes32 internal constant DANGLING_LEFT = bytes32(uint256(0xdad1));

    MultiLevelTournamentFactory internal immutable FACTORY;

    InputBox internal inputBox;
    LeafGasApplication internal application;
    DaveConsensus internal consensus;
    ITournament internal tournament;
    Match.Id internal matchId;
    Tree.Node internal winnerCommitment;
    Tree.Node internal danglingCommitment;
    ProofVector internal vector;
    uint256 internal proofInputSize;
    uint256 internal fundedBalance;

    constructor() {
        RiscVStateTransition riscV = new RiscVStateTransition();
        CmioStateTransition cmio = new CmioStateTransition();
        CartesiStateTransition stateTransition = new CartesiStateTransition(riscV, cmio);
        FACTORY = new MultiLevelTournamentFactory(new Tournament(), new LeafGasParametersProvider(), stateTransition);
    }

    receive() external payable {}

    function _initializeLeafGasFixture(uint256 counter, uint256[] memory payloadSizes, WinnerSide winner) internal {
        require(counter > 0);
        _initializeEnvironment();

        bytes[] memory inputs = _addInputs(payloadSizes);
        proofInputSize = _proofInputSize(counter, inputs);
        vector = _generateProof(counter, inputs);
        _initializeConsensusAndMatch(counter, winner);
    }

    function _initializeRevertLeafGasFixture(uint256 payloadSize, WinnerSide winner) internal {
        _initializeEnvironment();

        uint256[] memory payloadSizes = new uint256[](1);
        payloadSizes[0] = payloadSize;
        bytes[] memory inputs = _addInputs(payloadSizes);
        uint256 counter;
        (counter, vector) = _generateRevertProof(inputs);
        _initializeConsensusAndMatch(counter, winner);
    }

    function _initializeEnvironment() private {
        vm.roll(100);
        vm.warp(1_000);
        vm.fee(0);
        vm.txGasPrice(0);

        inputBox = new InputBox();
        application = new LeafGasApplication();
    }

    function _addInputs(uint256[] memory payloadSizes) private returns (bytes[] memory inputs) {
        inputs = new bytes[](payloadSizes.length);
        for (uint256 i; i < payloadSizes.length; ++i) {
            inputs[i] = _addInput(_nonzeroBytes(payloadSizes[i]));
        }
        return inputs;
    }

    function _initializeConsensusAndMatch(uint256 counter, WinnerSide winner) private {
        consensus = new DaveConsensus(
            inputBox, address(application), FACTORY, vector.epochInitialState, 0, address(this), new address[](0)
        );

        _initializeMatch(counter, winner);
    }

    function _initializeMatch(uint256 counter, WinnerSide winner) private {
        // A right-branch divergence makes the fixture a coherent two-state
        // commitment and exercises the nonzero-position settlement path.
        Tree.Node agree = Tree.Node.wrap(Machine.Hash.unwrap(vector.agreeState));
        Tree.Node correct = Tree.Node
            .wrap(
                keccak256(
                    abi.encodePacked(Machine.Hash.unwrap(vector.agreeState), Machine.Hash.unwrap(vector.nextState))
                )
            );
        Tree.Node incorrect =
            Tree.Node.wrap(keccak256(abi.encodePacked(Machine.Hash.unwrap(vector.agreeState), WRONG_STATE)));

        Tree.Node one = winner == WinnerSide.ONE ? correct : incorrect;
        Tree.Node two = winner == WinnerSide.ONE ? incorrect : correct;
        Machine.Hash finalOne = winner == WinnerSide.ONE ? vector.nextState : Machine.Hash.wrap(WRONG_STATE);
        Machine.Hash finalTwo = winner == WinnerSide.ONE ? Machine.Hash.wrap(WRONG_STATE) : vector.nextState;

        tournament = FACTORY.instantiateInner(
            vector.tournamentInitialState,
            one,
            finalOne,
            two,
            finalTwo,
            Time.Duration.wrap(LeafGasGeometry.MAX_ALLOWANCE),
            counter - 1,
            LEAF_LEVEL,
            IDataProvider(address(consensus))
        );

        _join(one, finalOne, agree, Tree.Node.wrap(Machine.Hash.unwrap(finalOne)));
        _join(two, finalTwo, agree, Tree.Node.wrap(Machine.Hash.unwrap(finalTwo)));
        matchId = Match.Id(one, two);
        winnerCommitment = winner == WinnerSide.ONE ? one : two;

        Tree.Node danglingRight = Tree.Node.wrap(Machine.Hash.unwrap(finalOne));
        danglingCommitment = _danglingLeftNode().join(danglingRight);
        _join(danglingCommitment, finalOne, _danglingLeftNode(), danglingRight);

        bytes32[] memory agreeProof = new bytes32[](1);
        agreeProof[0] = Machine.Hash.unwrap(finalOne);
        tournament.sealLeafMatch(
            matchId, agree, Tree.Node.wrap(Machine.Hash.unwrap(finalOne)), vector.agreeState, agreeProof
        );

        assertEq(tournament.getMatchCycle(Match.hashFromId(matchId)), counter);
        fundedBalance = address(tournament).balance;
        assertEq(fundedBalance, 3 * tournament.bondValue());
    }

    function _danglingLeftNode() private pure returns (Tree.Node) {
        return Tree.Node.wrap(DANGLING_LEFT);
    }

    function _join(Tree.Node root, Machine.Hash finalState, Tree.Node left, Tree.Node right) private {
        assertTrue(root.eq(left.join(right)));
        bytes32[] memory finalProof = new bytes32[](1);
        finalProof[0] = Tree.Node.unwrap(left);
        uint256 bond = tournament.bondValue();
        vm.deal(address(this), address(this).balance + bond);
        tournament.joinTournament{value: bond}(finalState, finalProof, left, right);
    }

    function _addInput(bytes memory payload) private returns (bytes memory input) {
        uint256 index = inputBox.getNumberOfInputs(address(application));
        vm.recordLogs();
        inputBox.addInput(address(application), payload);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 inputEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(inputBox) || entry.topics[0] != IInputBox.InputAdded.selector) {
                continue;
            }
            ++inputEvents;
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(application)))));
            assertEq(entry.topics[2], bytes32(index));
            input = abi.decode(entry.data, (bytes));
        }
        assertEq(inputEvents, 1);
    }

    function _generateProof(uint256 counter, bytes[] memory inputs) private returns (ProofVector memory generated) {
        string[] memory cmd = _proofCommand(vm.toString(counter), inputs);

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory encoded = vm.ffi(cmd);
        (
            bytes32 epochInitialState,
            bytes32 tournamentInitialState,
            bytes32 agreeState,
            bytes32 nextState,
            bytes memory proof
        ) = abi.decode(encoded, (bytes32, bytes32, bytes32, bytes32, bytes));
        generated = ProofVector({
            epochInitialState: Machine.Hash.wrap(epochInitialState),
            tournamentInitialState: Machine.Hash.wrap(tournamentInitialState),
            agreeState: Machine.Hash.wrap(agreeState),
            nextState: Machine.Hash.wrap(nextState),
            proof: proof
        });
    }

    function _generateRevertProof(bytes[] memory inputs)
        private
        returns (uint256 counter, ProofVector memory generated)
    {
        string[] memory cmd = _proofCommand("revert", inputs);

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory encoded = vm.ffi(cmd);
        bytes32 epochInitialState;
        bytes32 tournamentInitialState;
        bytes32 agreeState;
        bytes32 nextState;
        bytes memory proof;
        (counter, epochInitialState, tournamentInitialState, agreeState, nextState, proof) =
            abi.decode(encoded, (uint256, bytes32, bytes32, bytes32, bytes32, bytes));
        generated = ProofVector({
            epochInitialState: Machine.Hash.wrap(epochInitialState),
            tournamentInitialState: Machine.Hash.wrap(tournamentInitialState),
            agreeState: Machine.Hash.wrap(agreeState),
            nextState: Machine.Hash.wrap(nextState),
            proof: proof
        });
    }

    function _proofInputSize(uint256 counter, bytes[] memory inputs) private pure returns (uint256) {
        if (counter % INPUT_SPAN != 0) return 0;
        uint256 inputIndex = counter / INPUT_SPAN;
        return inputIndex < inputs.length ? inputs[inputIndex].length : 0;
    }

    function _proofCommand(string memory mode, bytes[] memory inputs) private pure returns (string[] memory cmd) {
        uint256 argumentCount = 3;
        for (uint256 i; i < inputs.length; ++i) {
            argumentCount += 1 + _chunkCount(inputs[i].length);
        }

        cmd = new string[](argumentCount);
        cmd[0] = "lua";
        cmd[1] = "test/gas/generate-leaf-proof.lua";
        cmd[2] = mode;

        uint256 next = 3;
        for (uint256 i; i < inputs.length; ++i) {
            cmd[next++] = "input";
            for (uint256 offset; offset < inputs[i].length; offset += FFI_INPUT_CHUNK_BYTES) {
                uint256 remaining = inputs[i].length - offset;
                uint256 length = remaining < FFI_INPUT_CHUNK_BYTES ? remaining : FFI_INPUT_CHUNK_BYTES;
                cmd[next++] = vm.toString(_slice(inputs[i], offset, length));
            }
        }
        assert(next == argumentCount);
    }

    function _chunkCount(uint256 length) private pure returns (uint256) {
        return (length + FFI_INPUT_CHUNK_BYTES - 1) / FFI_INPUT_CHUNK_BYTES;
    }

    function _slice(bytes memory data, uint256 offset, uint256 length) private pure returns (bytes memory chunk) {
        chunk = new bytes(length);
        for (uint256 i; i < length; ++i) {
            chunk[i] = data[offset + i];
        }
    }

    function _measureLeafWin(string memory label) internal returns (Measurement memory result) {
        Tree.Node agree = Tree.Node.wrap(Machine.Hash.unwrap(vector.agreeState));
        Tree.Node next = Tree.Node.wrap(Machine.Hash.unwrap(vector.nextState));
        bytes memory callData = abi.encodeCall(ITournament.winLeafMatch, (matchId, agree, next, vector.proof));
        (result.zeroCalldataBytes, result.nonzeroCalldataBytes) = _byteComposition(callData);
        result.calldataBytes = callData.length;

        vm.fee(0);
        vm.txGasPrice(1);
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = address(tournament).call(callData);
        result.completeCallGas = gasBefore - gasleft();
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 refundEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(tournament) || entry.topics[0] != ITournament.PartialBondRefund.selector) {
                continue;
            }
            ++refundEvents;
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(this)))));
            assertEq(entry.topics[2], bytes32(uint256(1)));
            result.allocationUnits = abi.decode(entry.data, (uint256));
        }
        assertEq(refundEvents, 1);
        assertGt(result.allocationUnits, Gas.TX);
        assertLt(result.allocationUnits, Bond.actionRefundCap(Gas.WIN_LEAF_MATCH));
        assertLt(result.allocationUnits, fundedBalance);
        assertLe(_minimumReviewedAllocation(result), Gas.WIN_LEAF_MATCH);

        Match.State memory oldMatch = tournament.getMatch(Match.hashFromId(matchId));
        assertFalse(Match.exists(oldMatch));
        Match.Id memory repaired = Match.Id(danglingCommitment, winnerCommitment);
        assertTrue(Match.exists(tournament.getMatch(Match.hashFromId(repaired))));
        assertEq(tournament.getMatchCreatedCount(), 2);
        assertEq(tournament.getMatchDeletedCount(), 1);

        _logMeasurement(label, result);
    }

    function _logMeasurement(string memory label, Measurement memory result) private {
        emit log_named_uint(label, result.allocationUnits);
        emit log_named_uint(string.concat(label, " reviewed minimum"), _minimumReviewedAllocation(result));
        emit log_named_uint(
            string.concat(label, " rounded recommendation"), _roundUpToThousand(_minimumReviewedAllocation(result))
        );
        emit log_named_uint(string.concat(label, " complete call"), result.completeCallGas);
        emit log_named_uint(string.concat(label, " proof bytes"), vector.proof.length);
        emit log_named_bytes32(string.concat(label, " proof keccak"), keccak256(vector.proof));
        emit log_named_uint(string.concat(label, " proof input bytes"), proofInputSize);
        emit log_named_uint(string.concat(label, " calldata bytes"), result.calldataBytes);
        emit log_named_uint(string.concat(label, " zero calldata bytes"), result.zeroCalldataBytes);
        emit log_named_uint(string.concat(label, " nonzero calldata bytes"), result.nonzeroCalldataBytes);

        uint256 tokens = result.zeroCalldataBytes + 4 * result.nonzeroCalldataBytes;
        emit log_named_uint(string.concat(label, " legacy calldata intrinsic"), 21_000 + 4 * tokens);
        emit log_named_uint(string.concat(label, " Prague calldata floor"), 21_000 + 10 * tokens);
        emit log_named_uint(
            string.concat(label, " Prague transaction estimate"),
            21_000 + _max(4 * tokens + result.completeCallGas, 10 * tokens)
        );
    }

    function _minimumReviewedAllocation(Measurement memory result) internal pure returns (uint256) {
        uint256 measuredDelta = result.allocationUnits - Gas.TX;
        uint256 proportionalMargin = (measuredDelta + 9) / 10;
        uint256 margin = proportionalMargin > 10_000 ? proportionalMargin : 10_000;
        return result.allocationUnits + margin;
    }

    function _roundUpToThousand(uint256 value) internal pure returns (uint256) {
        return (value + 999) / 1000 * 1000;
    }

    function _assertPayloadAboveMaximumRejected() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IInputBox.InputTooLarge.selector, address(application), FIRST_REJECTED_INPUT_SIZE, INPUT_MAX_SIZE
            )
        );
        inputBox.addInput(address(application), _nonzeroBytes(MAX_PAYLOAD_SIZE + 1));
    }

    function _nonzeroBytes(uint256 length) private pure returns (bytes memory data) {
        data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = 0xff;
        }
    }

    function _byteComposition(bytes memory data) private pure returns (uint256 zeroBytes, uint256 nonzeroBytes) {
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++zeroBytes;
            else ++nonzeroBytes;
        }
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
