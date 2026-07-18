// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

contract CallbackParametersProvider is ITournamentParametersProvider {
    function tournamentParameters(uint64)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: 1,
            log2step: 0,
            height: 1,
            matchEffort: Time.Duration.wrap(0),
            maxAllowance: Time.Duration.wrap(1)
        });
    }
}

contract CallbackStateTransition is IStateTransition {
    function transitionState(
        bytes32 machineState,
        uint256,
        bytes calldata,
        IDataProvider
    ) external pure override returns (bytes32) {
        return machineState;
    }
}

contract PaymentCallbackReceiver {
    enum Behavior {
        ACCEPT,
        EXHAUST_GAS,
        RETURN_LARGE_DATA,
        REVERT_LARGE_DATA,
        REENTER_RECOVERY
    }

    Behavior public behavior;
    uint256 public entryGas;
    bool public reentrySucceeded;

    constructor(Behavior initialBehavior) {
        behavior = initialBehavior;
    }

    function setBehavior(Behavior newBehavior) external {
        behavior = newBehavior;
    }

    function invoke(address target, bytes calldata data) external {
        (bool success, bytes memory ret) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function invokeThenExpectFailure(
        address target,
        bytes calldata firstCall,
        bytes calldata secondCall
    ) external returns (bytes memory secondRet) {
        (bool firstSuccess, bytes memory firstRet) = target.call(firstCall);
        if (!firstSuccess) {
            assembly ("memory-safe") {
                revert(add(firstRet, 32), mload(firstRet))
            }
        }

        (bool secondSuccess, bytes memory ret) = target.call(secondCall);
        require(!secondSuccess);
        return ret;
    }

    receive() external payable {
        Behavior current = behavior;
        if (current == Behavior.EXHAUST_GAS) {
            assembly ("memory-safe") {
                for {} 1 {} { pop(keccak256(0, 0)) }
            }
        }
        if (current == Behavior.RETURN_LARGE_DATA) {
            assembly {
                return(0, 0x10000)
            }
        }
        if (current == Behavior.REVERT_LARGE_DATA) {
            assembly {
                revert(0, 0x10000)
            }
        }
        if (current == Behavior.REENTER_RECOVERY) {
            (reentrySucceeded,) = msg.sender
                .call(abi.encodeCall(ITournament.tryRecoveringBond, ()));
        }
        entryGas = gasleft();
    }
}

contract RefundCallbacksTest is Test {
    using Match for Match.Id;
    using Match for Match.State;
    using Tree for Tree.Node;

    uint256 internal constant WHOLE_CALL_GAS_CEILING = 1_000_000;
    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(0));
    Tree.Node internal constant INITIAL_NODE = Tree.Node.wrap(bytes32(0));

    MultiLevelTournamentFactory internal immutable factory;

    constructor() {
        factory = new MultiLevelTournamentFactory(
            new Tournament(),
            new CallbackParametersProvider(),
            new CallbackStateTransition()
        );
    }

    function testRefundCallbackReceivesBoundedGas() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.ACCEPT
        );
        bytes memory sealCall = _sealCall(matchId);
        uint256 tournamentBalanceBefore = address(tournament).balance;
        uint256 receiverBalanceBefore = address(receiver).balance;

        vm.recordLogs();
        receiver.invoke(address(tournament), sealCall);

        uint256 refund = address(receiver).balance - receiverBalanceBefore;
        assertTrue(tournament.getMatch(matchId.hashFromId()).isSealed());
        assertGt(refund, 0);
        assertEq(tournamentBalanceBefore - address(tournament).balance, refund);
        assertGt(receiver.entryGas(), 0);
        assertEq(Bond.PAYMENT_CALLBACK_GAS_LIMIT, 50_000);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(_refundEvent(tournament, receiver, true), refund);
    }

    function testGasExhaustingRefundCallbackCannotRevertProgress() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.EXHAUST_GAS
        );
        uint256 tournamentBalanceBefore = address(tournament).balance;

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        bytes memory secondRet = receiver.invokeThenExpectFailure(
            address(tournament),
            _sealCall(matchId),
            abi.encodeCall(ITournament.eliminateMatchByTimeout, (matchId))
        );
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(tournament.getMatch(matchId.hashFromId()).isSealed());
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, tournamentBalanceBefore);
        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertEq(
            bytes4(secondRet),
            ITournament.AtLeastOneClockHasNotTimedOut.selector
        );
        assertGt(_refundEvent(tournament, receiver, false), 0);
    }

    function testLargeRevertDataIsNotCopied() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.REVERT_LARGE_DATA
        );
        uint256 tournamentBalanceBefore = address(tournament).balance;

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        receiver.invoke(address(tournament), _sealCall(matchId));
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(tournament.getMatch(matchId.hashFromId()).isSealed());
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, tournamentBalanceBefore);
        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertGt(_refundEvent(tournament, receiver, false), 0);
    }

    function testLargeRefundReturnDataIsNotCopied() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.RETURN_LARGE_DATA
        );
        uint256 tournamentBalanceBefore = address(tournament).balance;

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        receiver.invoke(address(tournament), _sealCall(matchId));
        uint256 gasUsed = gasBefore - gasleft();

        uint256 refund = address(receiver).balance;
        assertTrue(tournament.getMatch(matchId.hashFromId()).isSealed());
        assertGt(refund, 0);
        assertEq(tournamentBalanceBefore - address(tournament).balance, refund);
        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertEq(_refundEvent(tournament, receiver, true), refund);
    }

    function testZeroRefundSkipsCallbackAndReportsSuccess() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.EXHAUST_GAS
        );
        vm.deal(address(tournament), 0);

        vm.recordLogs();
        receiver.invoke(address(tournament), _sealCall(matchId));

        assertTrue(tournament.getMatch(matchId.hashFromId()).isSealed());
        assertEq(address(receiver).balance, 0);
        assertEq(_refundEvent(tournament, receiver, true), 0);
    }

    function testTerminalCallbackReceivesBoundedGasAndIsIdempotent() public {
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.ACCEPT
        );
        ITournament tournament = _finishedTournament(address(receiver));
        uint256 bond = tournament.bondValue();

        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertGt(receiver.entryGas(), 0);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(address(tournament).balance, 0);

        uint256 entryGas = receiver.entryGas();
        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertEq(receiver.entryGas(), entryGas);
    }

    function testGasExhaustingTerminalCallbackPreservesRetry() public {
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.EXHAUST_GAS
        );
        ITournament tournament = _finishedTournament(address(receiver));
        uint256 bond = tournament.bondValue();

        uint256 gasBefore = gasleft();
        assertFalse(tournament.tryRecoveringBond());
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, bond);

        receiver.setBehavior(PaymentCallbackReceiver.Behavior.ACCEPT);
        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertGt(receiver.entryGas(), 0);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(address(tournament).balance, 0);
    }

    function testTerminalCallbackCannotReenterRecovery() public {
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.REENTER_RECOVERY
        );
        ITournament tournament = _finishedTournament(address(receiver));
        uint256 bond = tournament.bondValue();

        assertTrue(tournament.tryRecoveringBond());

        assertFalse(receiver.reentrySucceeded());
        assertEq(address(receiver).balance, bond);
        assertGt(receiver.entryGas(), 0);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(address(tournament).balance, 0);
        assertTrue(tournament.tryRecoveringBond());
    }

    function _matchFixture()
        internal
        returns (ITournament tournament, Match.Id memory matchId)
    {
        vm.roll(100);
        vm.fee(Bond.WORK_PRICE_CAP);
        vm.txGasPrice(Bond.WORK_PRICE_CAP);

        tournament =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        Tree.Node commitmentOne = _join(tournament, vm.addr(1), INITIAL_STATE);
        Tree.Node commitmentTwo = _join(
            tournament, vm.addr(2), Machine.Hash.wrap(bytes32(uint256(1)))
        );
        matchId = Match.Id(commitmentOne, commitmentTwo);
    }

    function _finishedTournament(address claimer)
        internal
        returns (ITournament tournament)
    {
        vm.roll(100);
        tournament =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        _join(tournament, claimer, INITIAL_STATE);
        vm.roll(101);
        assertTrue(tournament.isFinished());
    }

    function _join(
        ITournament tournament,
        address claimer,
        Machine.Hash finalState
    ) internal returns (Tree.Node commitment) {
        Tree.Node finalNode = Tree.Node.wrap(Machine.Hash.unwrap(finalState));
        commitment = INITIAL_NODE.join(finalNode);

        bytes32[] memory finalStateProof = new bytes32[](1);
        finalStateProof[0] = Tree.Node.unwrap(INITIAL_NODE);

        uint256 bond = tournament.bondValue();
        vm.deal(claimer, bond);
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            finalState, finalStateProof, INITIAL_NODE, finalNode
        );
    }

    function _sealCall(Match.Id memory matchId)
        internal
        pure
        returns (bytes memory)
    {
        bytes32[] memory agreeStateProof = new bytes32[](1);
        agreeStateProof[0] = Tree.Node.unwrap(INITIAL_NODE);
        return abi.encodeCall(
            ITournament.sealLeafMatch,
            (
                matchId,
                INITIAL_NODE,
                INITIAL_NODE,
                INITIAL_STATE,
                agreeStateProof
            )
        );
    }

    function _refundEvent(
        ITournament tournament,
        PaymentCallbackReceiver receiver,
        bool expectedSuccess
    ) internal returns (uint256 observedValue) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 refundEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(tournament)
                    || entry.topics[0] != ITournament.PartialBondRefund.selector
            ) {
                continue;
            }

            ++refundEvents;
            assertEq(
                entry.topics[1], bytes32(uint256(uint160(address(receiver))))
            );
            assertEq(entry.topics[2], bytes32(uint256(expectedSuccess ? 1 : 0)));
            (uint256 value, bytes memory ret) =
                abi.decode(entry.data, (uint256, bytes));
            observedValue = value;
            assertEq(ret, bytes(""));
        }
        assertEq(refundEvents, 1);
    }
}
