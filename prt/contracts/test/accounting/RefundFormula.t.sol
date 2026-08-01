// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Gas} from "src/tournament/libs/Gas.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {
    SmallSingleLevelGeometry,
    SmallSingleLevelTournamentFactory
} from "../fixtures/SmallSingleLevelTournament.sol";

contract FormulaRefundReceiver {
    error RefundRejected();

    bool internal immutable REJECTS;
    uint256 public received;

    constructor(bool rejects) {
        REJECTS = rejects;
    }

    receive() external payable {
        if (REJECTS) revert RefundRejected();
        received += msg.value;
    }
}

/// @dev Exercises the production refund modifier through a real timeout action.
/// Independent twins separate the measured action units from the balance and
/// fee-policy caps without adding instrumentation to Tournament.
contract RefundFormulaTest is Test {
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    enum Kink {
        ZERO_PRICE,
        WORK,
        BALANCE,
        PRIORITY,
        ALLOCATION,
        REJECTED_RECEIVER
    }

    struct Fixture {
        InspectableTournament tournament;
        Match.Id matchId;
        Match.Id repairedMatchId;
        Tree.Node winner;
        Tree.Node winnerLeft;
        Tree.Node winnerRight;
        bool repairsMatch;
    }

    struct Observation {
        uint256 value;
        bool success;
        uint256 tournamentBalanceBefore;
        uint256 tournamentBalanceAfter;
        uint256 recipientBalanceBefore;
        uint256 recipientBalanceAfter;
        int256 reportedGasRefund;
    }

    struct Case {
        uint256 baseFee;
        uint256 priorityFee;
        uint256 tournamentBalance;
        bool rejects;
    }

    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant MAX_ALLOWANCE = 1;
    uint256 internal constant MAX_FUZZ_BASE_FEE = 200 gwei;
    uint256 internal constant MAX_FUZZ_PRIORITY_FEE = 100 gwei;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xabc)));

    SmallSingleLevelTournamentFactory internal immutable FACTORY;

    Fixture[2] internal controls;
    Fixture[2] internal targets;

    constructor() {
        FACTORY = new SmallSingleLevelTournamentFactory(
            Time.ZERO_DURATION, Time.Duration.wrap(MAX_ALLOWANCE)
        );
    }

    receive() external payable {}

    function setUp() public {
        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);

        controls[0] = _newFixture(false);
        targets[0] = _newFixture(false);
        controls[1] = _newFixture(true);
        targets[1] = _newFixture(true);
    }

    function testFuzzProductionRefundFormula(
        uint96 rawBalance,
        uint64 rawBaseFee,
        uint64 rawPriorityFee,
        bool repairsMatch,
        bool rejects
    ) public {
        uint256 fixtureIndex = repairsMatch ? 1 : 0;
        vm.roll(START_BLOCK + MAX_ALLOWANCE);

        uint256 measuredUnits = _measureAtUnitPrice(controls[fixtureIndex]);
        uint256 actionCap = Bond.actionRefundCap(Gas.WIN_MATCH_BY_TIMEOUT);
        uint256 baseFee = bound(uint256(rawBaseFee), 0, MAX_FUZZ_BASE_FEE);
        uint256 priorityFee =
            bound(uint256(rawPriorityFee), 0, MAX_FUZZ_PRIORITY_FEE);
        uint256 targetBalance = bound(uint256(rawBalance), 0, 2 * actionCap);

        FormulaRefundReceiver receiver = new FormulaRefundReceiver(rejects);
        Case memory scenario = Case({
            baseFee: baseFee,
            priorityFee: priorityFee,
            tournamentBalance: targetBalance,
            rejects: rejects
        });

        _runAndAssertFormula(
            targets[fixtureIndex], receiver, measuredUnits, scenario
        );
    }

    function testDeterministicRefundKinkMatrix() public {
        for (
            uint256 rawKind;
            rawKind <= uint256(Kink.REJECTED_RECEIVER);
            ++rawKind
        ) {
            _runKink(Kink(rawKind), rawKind % 2 == 1);
        }
    }

    function testUnitPriceTwinsHaveEqualMeasuredUnits() public {
        vm.roll(START_BLOCK + MAX_ALLOWANCE);
        for (uint256 i; i < controls.length; ++i) {
            Observation memory control =
                _execute(controls[i], address(this), 0, 1, 2 * _actionCap());
            Observation memory target =
                _execute(targets[i], address(this), 0, 1, 2 * _actionCap());

            _assertSuccessfulTransfer(control, control.value);
            _assertSuccessfulTransfer(target, target.value);
            assertEq(target.value, control.value);
            assertGt(control.value, Gas.TX);
            assertLt(control.value, Gas.WIN_MATCH_BY_TIMEOUT);
            _assertProgress(controls[i]);
            _assertProgress(targets[i]);

            // Foundry's reported storage-refund counter is diagnostic here.
            // The protocol formula deliberately uses the gross gasleft delta.
            emit log_named_int(
                i == 0
                    ? "no-dangling control reported gas refund"
                    : "repair control reported gas refund",
                control.reportedGasRefund
            );
            emit log_named_int(
                i == 0
                    ? "no-dangling target reported gas refund"
                    : "repair target reported gas refund",
                target.reportedGasRefund
            );
        }
    }

    function _runKink(Kink kind, bool repairsMatch) private {
        vm.fee(0);
        vm.txGasPrice(0);
        Fixture memory control = _newFixture(repairsMatch);
        Fixture memory target = _newFixture(repairsMatch);
        // Read the mutated header through the cheatcode. Optimized Solidity may
        // cache block.number across repeated vm.roll calls in one test call.
        vm.roll(vm.getBlockNumber() + MAX_ALLOWANCE);

        uint256 measuredUnits = _measureAtUnitPrice(control);
        uint256 actionCap = _actionCap();
        uint256 workPrice = 1 gwei;
        Case memory scenario;

        if (kind == Kink.ZERO_PRICE) {
            scenario = Case({
                baseFee: 0,
                priorityFee: 0,
                tournamentBalance: 2 * actionCap,
                rejects: true
            });
        } else if (kind == Kink.WORK) {
            scenario = Case({
                baseFee: workPrice,
                priorityFee: 0,
                tournamentBalance: 2 * actionCap,
                rejects: false
            });
        } else if (kind == Kink.BALANCE) {
            uint256 balanceWorkCost = measuredUnits * workPrice;
            scenario = Case({
                baseFee: workPrice,
                priorityFee: 0,
                tournamentBalance: balanceWorkCost - 1,
                rejects: false
            });
        } else if (kind == Kink.PRIORITY) {
            scenario = Case({
                baseFee: workPrice,
                priorityFee: Bond.REFUND_PRIORITY_FEE_CAP + 1,
                tournamentBalance: 2 * actionCap,
                rejects: false
            });
        } else if (kind == Kink.ALLOCATION) {
            uint256 saturationPrice = (actionCap - 1) / measuredUnits + 1;
            scenario = Case({
                baseFee: saturationPrice + 1,
                priorityFee: 0,
                tournamentBalance: 2 * actionCap,
                rejects: false
            });
        } else {
            assert(kind == Kink.REJECTED_RECEIVER);
            scenario = Case({
                baseFee: workPrice,
                priorityFee: 0,
                tournamentBalance: 2 * actionCap,
                rejects: true
            });
        }

        FormulaRefundReceiver receiver =
            new FormulaRefundReceiver(scenario.rejects);
        Observation memory observed =
            _runAndAssertFormula(target, receiver, measuredUnits, scenario);

        uint256 effectivePrice = _effectivePrice(
            scenario.baseFee, scenario.baseFee + scenario.priorityFee
        );
        uint256 workCost = measuredUnits * effectivePrice;
        if (kind == Kink.ZERO_PRICE) {
            assertEq(observed.value, 0);
            assertTrue(observed.success);
        } else if (kind == Kink.WORK) {
            assertLt(workCost, actionCap);
            assertLt(workCost, scenario.tournamentBalance);
            assertEq(observed.value, workCost);
        } else if (kind == Kink.BALANCE) {
            assertLt(scenario.tournamentBalance, workCost);
            assertLt(scenario.tournamentBalance, actionCap);
            assertEq(observed.value, scenario.tournamentBalance);
        } else if (kind == Kink.PRIORITY) {
            assertEq(
                effectivePrice, scenario.baseFee + Bond.REFUND_PRIORITY_FEE_CAP
            );
            assertLt(effectivePrice, scenario.baseFee + scenario.priorityFee);
            assertEq(observed.value, workCost);
        } else if (kind == Kink.ALLOCATION) {
            assertGt(workCost, actionCap);
            assertEq(observed.value, actionCap);
        } else {
            assertGt(observed.value, 0);
            assertFalse(observed.success);
        }
    }

    function _runAndAssertFormula(
        Fixture memory fixture,
        FormulaRefundReceiver receiver,
        uint256 measuredUnits,
        Case memory scenario
    ) private returns (Observation memory observed) {
        uint256 gasPrice =
            scenario.baseFee + scenario.priorityFee;
        observed = _execute(
            fixture,
            address(receiver),
            scenario.baseFee,
            gasPrice,
            scenario.tournamentBalance
        );

        uint256 expected = _min(
            scenario.tournamentBalance,
            _actionCap(),
            measuredUnits * _effectivePrice(scenario.baseFee, gasPrice)
        );
        bool expectedSuccess = expected == 0 || !scenario.rejects;
        uint256 expectedTransfer = scenario.rejects ? 0 : expected;

        assertEq(observed.value, expected);
        assertEq(observed.success, expectedSuccess);
        assertEq(
            observed.tournamentBalanceBefore - observed.tournamentBalanceAfter,
            expectedTransfer
        );
        assertEq(
            observed.recipientBalanceAfter - observed.recipientBalanceBefore,
            expectedTransfer
        );
        assertEq(receiver.received(), expectedTransfer);
        _assertProgress(fixture);
    }

    function _measureAtUnitPrice(Fixture memory fixture)
        private
        returns (uint256 measuredUnits)
    {
        Observation memory observed =
            _execute(fixture, address(this), 0, 1, 2 * _actionCap());
        _assertSuccessfulTransfer(observed, observed.value);
        measuredUnits = observed.value;
        assertGt(measuredUnits, Gas.TX);
        assertLt(measuredUnits, Gas.WIN_MATCH_BY_TIMEOUT);
        _assertProgress(fixture);
    }

    function _execute(
        Fixture memory fixture,
        address recipient,
        uint256 baseFee,
        uint256 gasPrice,
        uint256 tournamentBalance
    ) private returns (Observation memory observed) {
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        vm.deal(address(fixture.tournament), tournamentBalance);

        observed.tournamentBalanceBefore = address(fixture.tournament).balance;
        observed.recipientBalanceBefore = recipient.balance;

        vm.recordLogs();
        vm.prank(recipient);
        fixture.tournament
            .winMatchByTimeout(
                fixture.matchId, fixture.winnerLeft, fixture.winnerRight
            );
        Vm.Gas memory callGas = vm.lastCallGas();
        observed.reportedGasRefund = int256(callGas.gasRefunded);

        (observed.value, observed.success) =
            _refundEvent(fixture.tournament, recipient);
        observed.tournamentBalanceAfter = address(fixture.tournament).balance;
        observed.recipientBalanceAfter = recipient.balance;
    }

    function _newFixture(bool repairsMatch)
        private
        returns (Fixture memory fixture)
    {
        fixture.tournament = InspectableTournament(
            address(
                FACTORY.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );

        SmallFullTree.Data memory one = SmallFullTree.build(
            bytes32(uint256(1)), SmallSingleLevelGeometry.HEIGHT
        );
        SmallFullTree.Data memory two = SmallFullTree.build(
            bytes32(uint256(2)), SmallSingleLevelGeometry.HEIGHT
        );
        SmallFullTree.Data memory dangling = SmallFullTree.build(
            bytes32(uint256(3)), SmallSingleLevelGeometry.HEIGHT
        );

        Tree.Node oneRoot = _join(fixture.tournament, one, vm.addr(1));
        fixture.winner = _join(fixture.tournament, two, vm.addr(2));
        fixture.matchId = Match.Id(oneRoot, fixture.winner);
        fixture.repairsMatch = repairsMatch;

        if (repairsMatch) {
            Tree.Node danglingRoot =
                _join(fixture.tournament, dangling, vm.addr(3));
            fixture.repairedMatchId = Match.Id(danglingRoot, fixture.winner);
        }

        (fixture.winnerLeft, fixture.winnerRight) =
            two.children(SmallSingleLevelGeometry.HEIGHT, 0);
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private returns (Tree.Node root) {
        (Tree.Node left, Tree.Node right) =
            tree.children(SmallSingleLevelGeometry.HEIGHT, 0);
        uint256 bond = tournament.bondValue();
        vm.deal(claimer, bond);
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
        return tree.root();
    }

    function _assertProgress(Fixture memory fixture) private view {
        assertFalse(
            fixture.tournament.getMatch(fixture.matchId.hashFromId()).exists()
        );
        (Tree.Node dangling, uint256 activeMatches, Time.Instant lastDeleted) =
            fixture.tournament.observedTopology();
        assertEq(Time.Instant.unwrap(lastDeleted), vm.getBlockNumber());
        assertEq(fixture.tournament.getMatchDeletedCount(), 1);

        if (fixture.repairsMatch) {
            assertTrue(dangling.isZero());
            assertEq(activeMatches, 1);
            assertTrue(
                fixture.tournament
                    .getMatch(fixture.repairedMatchId.hashFromId()).exists()
            );
            assertEq(fixture.tournament.getCommitmentJoinedCount(), 3);
            assertEq(fixture.tournament.getMatchCreatedCount(), 2);
            assertFalse(fixture.tournament.isFinished());
        } else {
            assertTrue(dangling.eq(fixture.winner));
            assertEq(activeMatches, 0);
            assertEq(fixture.tournament.getCommitmentJoinedCount(), 2);
            assertEq(fixture.tournament.getMatchCreatedCount(), 1);
            assertTrue(fixture.tournament.isFinished());
        }
    }

    function _assertSuccessfulTransfer(
        Observation memory observed,
        uint256 expected
    ) private pure {
        assertTrue(observed.success);
        assertEq(
            observed.tournamentBalanceBefore - observed.tournamentBalanceAfter,
            expected
        );
        assertEq(
            observed.recipientBalanceAfter - observed.recipientBalanceBefore,
            expected
        );
    }

    function _refundEvent(InspectableTournament tournament, address recipient)
        private
        returns (uint256 value, bool success)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(tournament) || entry.topics.length != 3
                    || entry.topics[0] != ITournament.PartialBondRefund.selector
            ) {
                continue;
            }

            ++count;
            assertEq(entry.topics[1], bytes32(uint256(uint160(recipient))));
            assertTrue(
                entry.topics[2] == bytes32(0)
                    || entry.topics[2] == bytes32(uint256(1))
            );
            success = entry.topics[2] == bytes32(uint256(1));
            value = abi.decode(entry.data, (uint256));
        }
        assertEq(count, 1);
    }

    function _effectivePrice(uint256 baseFee, uint256 gasPrice)
        private
        pure
        returns (uint256)
    {
        uint256 priorityCappedPrice = baseFee + Bond.REFUND_PRIORITY_FEE_CAP;
        return gasPrice < priorityCappedPrice ? gasPrice : priorityCappedPrice;
    }

    function _actionCap() private pure returns (uint256) {
        return Bond.actionRefundCap(Gas.WIN_MATCH_BY_TIMEOUT);
    }

    function _min(uint256 a, uint256 b, uint256 c)
        private
        pure
        returns (uint256)
    {
        uint256 first = a < b ? a : b;
        return first < c ? first : c;
    }
}
