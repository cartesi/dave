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

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

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
            responseBudget: Time.Duration.wrap(0),
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

contract InspectableCallbackTournament is Tournament {
    function claimerOf(Tree.Node commitment) external view returns (address) {
        return claimers[commitment];
    }
}

contract PaymentCallbackReceiver {
    enum Behavior {
        ACCEPT,
        EXHAUST_GAS,
        RETURN_LARGE_DATA,
        REVERT_LARGE_DATA,
        REENTER_RECOVERY,
        REENTER_OTHER_RECOVERY
    }

    bytes4 public constant RECOVERY_SUCCEEDED = 0xffffffff;

    Behavior public behavior;
    bytes4 public recoveryCallResult;
    ITournament public recoveryTarget;
    uint256 public entryGas;

    constructor(Behavior initialBehavior) {
        behavior = initialBehavior;
    }

    function setBehavior(Behavior newBehavior) external {
        behavior = newBehavior;
    }

    function setRecoveryTarget(ITournament newTarget) external {
        recoveryTarget = newTarget;
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
            _recordRecoveryCall(msg.sender);
            return;
        }
        if (current == Behavior.REENTER_OTHER_RECOVERY) {
            _recordRecoveryCall(address(recoveryTarget));
            return;
        }
        entryGas = gasleft();
    }

    function _recordRecoveryCall(address target) private {
        (bool success, bytes memory ret) =
            target.call(abi.encodeCall(ITournament.tryRecoveringBond, ()));
        if (success) {
            recoveryCallResult = RECOVERY_SUCCEEDED;
            return;
        }

        bytes4 selector;
        if (ret.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(ret, 32))
            }
        }
        recoveryCallResult = selector;
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
            new InspectableCallbackTournament(),
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
        _assertSealedMatch(tournament, matchId);
        assertGt(refund, 0);
        assertEq(tournamentBalanceBefore - address(tournament).balance, refund);
        assertGt(receiver.entryGas(), 0);
        assertEq(Bond.PAYMENT_CALLBACK_GAS_LIMIT, 50_000);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(_refundEvent(tournament, receiver, true), refund);
    }

    function testRefundCallbackCannotReenterSameTournament() public {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.REENTER_RECOVERY
        );
        uint256 tournamentBalanceBefore = address(tournament).balance;

        vm.recordLogs();
        receiver.invoke(address(tournament), _sealCall(matchId));

        uint256 refund = address(receiver).balance;
        _assertSealedMatch(tournament, matchId);
        assertEq(
            receiver.recoveryCallResult(),
            ITournament.ReentrancyDetected.selector
        );
        assertGt(refund, 0);
        assertEq(tournamentBalanceBefore - address(tournament).balance, refund);
        assertEq(_refundEvent(tournament, receiver, true), refund);
    }

    function testCallbackBehaviorDoesNotChangeRequestedRefund() public {
        uint256 accepted =
            _requestedSealRefund(PaymentCallbackReceiver.Behavior.ACCEPT, true);
        uint256 rejected = _requestedSealRefund(
            PaymentCallbackReceiver.Behavior.EXHAUST_GAS, false
        );
        uint256 reentrant = _requestedSealRefund(
            PaymentCallbackReceiver.Behavior.REENTER_RECOVERY, true
        );

        assertGt(accepted, 0);
        assertEq(rejected, accepted);
        assertEq(reentrant, accepted);
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

        _assertSealedMatch(tournament, matchId);
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, tournamentBalanceBefore);
        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertEq(
            bytes4(secondRet),
            ITournament.MatchCannotBeEliminatedByTimeout.selector
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

        _assertSealedMatch(tournament, matchId);
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
        _assertSealedMatch(tournament, matchId);
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

        _assertSealedMatch(tournament, matchId);
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
        (ITournament tournament, Tree.Node winner) =
            _finishedTournamentWithWinner(address(receiver));
        uint256 bond = tournament.bondValue();
        uint256 fundedBalance = 2 * bond;
        vm.deal(address(tournament), fundedBalance);

        uint256 gasBefore = gasleft();
        assertFalse(tournament.tryRecoveringBond());
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, WHOLE_CALL_GAS_CEILING);
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, fundedBalance);
        assertEq(_claimerOf(tournament, winner), address(receiver));

        receiver.setBehavior(PaymentCallbackReceiver.Behavior.ACCEPT);
        uint256 burnedBalanceBefore = address(0).balance;
        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertGt(receiver.entryGas(), 0);
        assertLe(receiver.entryGas(), Bond.PAYMENT_CALLBACK_GAS_LIMIT);
        assertEq(address(tournament).balance, 0);
        assertEq(address(0).balance - burnedBalanceBefore, bond);
        assertEq(_claimerOf(tournament, winner), address(0));
    }

    function testTerminalCallbackCannotReenterRecovery() public {
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.REENTER_RECOVERY
        );
        (ITournament tournament, Tree.Node winner) =
            _finishedTournamentWithWinner(address(receiver));
        uint256 bond = tournament.bondValue();
        vm.deal(address(tournament), 2 * bond);
        uint256 burnedBalanceBefore = address(0).balance;

        assertTrue(tournament.tryRecoveringBond());

        assertEq(
            receiver.recoveryCallResult(),
            ITournament.ReentrancyDetected.selector
        );
        assertEq(address(receiver).balance, bond);
        assertEq(address(tournament).balance, 0);
        assertEq(address(0).balance - burnedBalanceBefore, bond);
        assertEq(_claimerOf(tournament, winner), address(0));

        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertEq(address(0).balance - burnedBalanceBefore, bond);
    }

    function testPaymentCallbackCanRecoverDifferentTournament() public {
        address secondClaimer = vm.addr(1234);
        (ITournament second, Tree.Node secondWinner) =
            _finishedTournamentWithWinner(secondClaimer);
        vm.deal(address(second), 0);
        assertEq(_claimerOf(second, secondWinner), secondClaimer);

        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(
            PaymentCallbackReceiver.Behavior.REENTER_OTHER_RECOVERY
        );
        receiver.setRecoveryTarget(second);
        (ITournament first, Tree.Node firstWinner) =
            _finishedTournamentWithWinner(address(receiver));
        uint256 firstBond = first.bondValue();

        assertTrue(first.tryRecoveringBond());

        assertEq(receiver.recoveryCallResult(), receiver.RECOVERY_SUCCEEDED());
        assertEq(address(receiver).balance, firstBond);
        assertEq(address(first).balance, 0);
        assertEq(_claimerOf(first, firstWinner), address(0));
        assertEq(address(second).balance, 0);
        assertEq(_claimerOf(second, secondWinner), address(0));
        assertEq(secondClaimer.balance, 0);
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
        (tournament,) = _finishedTournamentWithWinner(claimer);
    }

    function _finishedTournamentWithWinner(address claimer)
        internal
        returns (ITournament tournament, Tree.Node winner)
    {
        vm.roll(100);
        tournament =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        winner = _join(tournament, claimer, INITIAL_STATE);
        vm.roll(101);
        assertTrue(tournament.isFinished());
    }

    function _requestedSealRefund(
        PaymentCallbackReceiver.Behavior behavior,
        bool expectedSuccess
    ) internal returns (uint256) {
        (ITournament tournament, Match.Id memory matchId) = _matchFixture();
        PaymentCallbackReceiver receiver = new PaymentCallbackReceiver(behavior);

        vm.recordLogs();
        receiver.invoke(address(tournament), _sealCall(matchId));

        _assertSealedMatch(tournament, matchId);
        return _refundEvent(tournament, receiver, expectedSuccess);
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
            observedValue = abi.decode(entry.data, (uint256));
        }
        assertEq(refundEvents, 1);
    }

    function _assertSealedMatch(ITournament tournament, Match.Id memory matchId)
        internal
        view
    {
        Match.State memory state = tournament.getMatch(matchId.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
    }

    function _claimerOf(ITournament tournament, Tree.Node commitment)
        internal
        view
        returns (address)
    {
        return InspectableCallbackTournament(address(tournament))
            .claimerOf(commitment);
    }
}
