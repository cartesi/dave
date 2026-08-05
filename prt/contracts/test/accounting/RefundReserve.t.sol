// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

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
import {Clock} from "src/tournament/libs/Clock.sol";
import {Gas} from "src/tournament/libs/Gas.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

contract MutableRefundParametersProvider is ITournamentParametersProvider {
    uint64 internal height = 1;
    uint64 internal levels = 1;

    function setHeight(uint64 newHeight) external {
        height = newHeight;
    }

    function setLevels(uint64 newLevels) external {
        levels = newLevels;
    }

    function tournamentParameters(uint64)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: levels,
            log2step: 0,
            height: height,
            responseBudget: Time.Duration.wrap(0),
            maxAllowance: Time.Duration.wrap(1)
        });
    }
}

contract RefundStateTransition is IStateTransition {
    function transitionState(
        bytes32 machineState,
        uint256,
        bytes calldata,
        IDataProvider
    ) external pure override returns (bytes32) {
        return machineState;
    }
}

contract RefundReserveTest is Test {
    using Tree for Tree.Node;

    enum TerminalPath {
        TIMEOUT_WIN,
        TIMEOUT_ELIMINATION,
        LEAF_PROOF,
        LEAF_TIMEOUT_WIN,
        LEAF_TIMEOUT_ELIMINATION,
        INNER_WIN,
        INNER_ELIMINATION
    }

    uint256 internal constant MAX_MODEL_OPERATIONS = 64;
    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(0));
    Tree.Node internal constant INITIAL_NODE = Tree.Node.wrap(bytes32(0));

    MutableRefundParametersProvider internal immutable provider;
    MultiLevelTournamentFactory internal immutable factory;

    constructor() {
        provider = new MutableRefundParametersProvider();
        factory = new MultiLevelTournamentFactory(
            new Tournament(), provider, new RefundStateTransition()
        );
    }

    receive() external payable {}

    function testRoleSpecificBondPolicyCheckpoint() public {
        assertEq(Bond.WORK_PRICE_CAP, 50 gwei);
        assertEq(Bond.REFUND_PRIORITY_FEE_CAP, 10 gwei);
        uint256 leafTerminal = Bond.terminalAllocation(true);
        uint256 nonLeafTerminal = Bond.terminalAllocation(false);
        assertEq(Gas.WIN_LEAF_MATCH, 4_296_000);
        assertEq(leafTerminal, 4_401_000);
        assertEq(nonLeafTerminal, 699_000);
        assertEq(Bond.actionRefundCap(Gas.WIN_LEAF_MATCH), 0.2148 ether);
        assertEq(Bond.matchWorkAllocation(48, false), 6_574_000);
        assertEq(Bond.matchWorkAllocation(17, false), 2_699_000);
        assertEq(Bond.matchWorkAllocation(27, true), 7_651_000);
        assertEq(Bond.matchWorkAllocation(55, false), 7_449_000);
        assertEq(Bond.matchWorkAllocation(37, true), 8_901_000);
        assertEq(Bond.bondValue(48, false), 0.3287 ether);
        assertEq(Bond.bondValue(17, false), 0.13495 ether);
        assertEq(Bond.bondValue(27, true), 0.38255 ether);
        assertEq(Bond.bondValue(55, false), 0.37245 ether);
        assertEq(Bond.bondValue(37, true), 0.44505 ether);

        uint256 invalidZeroLeafWork = leafTerminal - Gas.ADVANCE_MATCH;
        uint256 invalidZeroLeafBond = invalidZeroLeafWork * Bond.WORK_PRICE_CAP;
        uint256 invalidZeroNonLeafWork = nonLeafTerminal - Gas.ADVANCE_MATCH;
        uint256 invalidZeroNonLeafBond =
            invalidZeroNonLeafWork * Bond.WORK_PRICE_CAP;
        assertEq(
            Bond.bondValue(0, true),
            invalidZeroLeafBond,
            "invalid leaf height zero must follow the explicit formula"
        );
        assertEq(
            Bond.bondValue(0, false),
            invalidZeroNonLeafBond,
            "invalid non-leaf height zero must follow the explicit formula"
        );
        provider.setHeight(0);
        ITournament zeroHeightTournament =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));
        assertEq(
            zeroHeightTournament.bondValue(),
            invalidZeroLeafBond,
            "tournament must expose the explicit invalid-zero formula"
        );
        assertEq(
            Bond.bondValue(1, true),
            leafTerminal * Bond.WORK_PRICE_CAP,
            "height one minimum bond must equal its terminal work reserve"
        );
    }

    function testTournamentBondValueUsesTournamentRole() public {
        provider.setHeight(27);

        ITournament singleLevelRoot =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));
        assertEq(singleLevelRoot.bondValue(), Bond.bondValue(27, true));

        provider.setLevels(2);
        ITournament nonLeafRoot =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));
        assertEq(nonLeafRoot.bondValue(), Bond.bondValue(27, false));

        ITournament leafChild = factory.instantiateInner(
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            Time.Duration.wrap(1),
            0,
            1,
            IDataProvider(address(0))
        );
        assertEq(leafChild.bondValue(), Bond.bondValue(27, true));
    }

    function testFuzzBondFormulaAndActionCapAlgebra(
        uint64 height,
        bool isLeafTournament
    ) public {
        provider.setHeight(height);
        provider.setLevels(isLeafTournament ? 1 : 2);

        ITournament tournament =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));

        uint256 work = _matchWorkAllocation(height, isLeafTournament);
        uint256 bond = work * Bond.WORK_PRICE_CAP;
        assertEq(Bond.matchWorkAllocation(height, isLeafTournament), work);
        assertEq(Bond.bondValue(height, isLeafTournament), bond);
        assertEq(tournament.bondValue(), bond);

        uint256[8] memory allocations = [
            Gas.ADVANCE_MATCH,
            Gas.WIN_MATCH_BY_TIMEOUT,
            Gas.ELIMINATE_MATCH_BY_TIMEOUT,
            Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT,
            Gas.WIN_INNER_TOURNAMENT,
            Gas.ELIMINATE_INNER_TOURNAMENT,
            Gas.SEAL_LEAF_MATCH,
            Gas.WIN_LEAF_MATCH
        ];

        for (uint256 i; i < allocations.length; ++i) {
            uint256 allocation = allocations[i];
            assertEq(
                Bond.actionRefundCap(allocation),
                allocation * Bond.WORK_PRICE_CAP
            );
        }
    }

    function testFuzzCurrentLegalPathsFitMatchWorkReserve(
        uint64 height,
        bool isLeafTournament
    ) public pure {
        height = uint64(bound(height, 1, type(uint64).max));
        uint256 workReserve = _matchWorkAllocation(height, isLeafTournament);
        uint256 largestLegalPath;
        uint256 pathCount = isLeafTournament ? 5 : 4;

        for (uint256 path; path < pathCount; ++path) {
            uint256 pathAllocation =
                _pathAllocation(height, _terminalPath(isLeafTournament, path));
            assertLe(pathAllocation, workReserve);
            if (pathAllocation > largestLegalPath) {
                largestLegalPath = pathAllocation;
            }
        }

        assertEq(
            largestLegalPath,
            workReserve,
            "reserve must equal the largest current legal path"
        );
    }

    function testFuzzPairingTopologyPreservesWinnerDeposit(
        uint64 height,
        bool isLeafTournament,
        bytes calldata operations
    ) public pure {
        height = uint64(bound(height, 1, type(uint64).max));

        uint256 bond = Bond.bondValue(height, isLeafTournament);
        uint256 matchWork = _matchWorkAllocation(height, isLeafTournament)
            * Bond.WORK_PRICE_CAP;
        assertEq(bond, matchWork);

        uint256 joins = 1;
        uint256 liveCommitments = 1;
        uint256 dangling = 1;
        uint256 activeMatches;
        uint256 matchesCreated;
        uint256 matchesResolved;
        uint256 resolvedMatchAllocation;

        uint256 operationCount = operations.length < MAX_MODEL_OPERATIONS
            ? operations.length
            : MAX_MODEL_OPERATIONS;
        for (uint256 i; i < operationCount; ++i) {
            uint8 operation = uint8(operations[i]);

            if (operation % 3 == 0) {
                ++joins;
                ++liveCommitments;
                if (dangling == 0) {
                    dangling = 1;
                } else {
                    dangling = 0;
                    ++activeMatches;
                    ++matchesCreated;
                }
            } else if (activeMatches > 0) {
                --activeMatches;
                ++matchesResolved;
                TerminalPath path =
                    _terminalPath(isLeafTournament, operation / 3);
                // Cost and survivor outcome are intentionally independent.
                // This conservatively composes any current path cost with
                // either population transition.
                resolvedMatchAllocation += _pathAllocation(height, path)
                * Bond.WORK_PRICE_CAP;

                if (operation % 3 == 1) {
                    --liveCommitments;
                    if (dangling == 0) {
                        dangling = 1;
                    } else {
                        dangling = 0;
                        ++activeMatches;
                        ++matchesCreated;
                    }
                } else {
                    liveCommitments -= 2;
                }
            }

            assertEq(
                liveCommitments,
                dangling + 2 * activeMatches,
                "live population accounting"
            );
            assertLe(matchesResolved, matchesCreated);
            assertLe(matchesCreated, joins - 1);
            assertLe(resolvedMatchAllocation, matchesResolved * matchWork);
            uint256 currentWorstCaseLiability = matchesCreated * matchWork;
            assertGe(joins * bond - currentWorstCaseLiability, bond);
        }

        assertEq(liveCommitments, dangling + 2 * activeMatches);
        assertLe(matchesResolved, matchesCreated);
        assertLe(matchesCreated, joins - 1);
        assertLe(resolvedMatchAllocation, matchesResolved * matchWork);
        uint256 finalWorstCaseLiability = matchesCreated * matchWork;
        assertGe(joins * bond - finalWorstCaseLiability, bond);
    }

    function testFuzzHeightOneRepeatedWinnerPreservesDepositAndWorkDisposition(uint8 losingCommitments)
        public
    {
        losingCommitments = uint8(bound(losingCommitments, 1, 8));
        provider.setHeight(1);
        vm.roll(100);
        vm.fee(Bond.WORK_PRICE_CAP);
        vm.txGasPrice(Bond.WORK_PRICE_CAP);

        ITournament tournament =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        uint256 bond = tournament.bondValue();
        uint256 refundRecipientBalanceBefore = address(this).balance;

        Machine.Hash winnerState = INITIAL_STATE;
        address winnerClaimer = vm.addr(100);
        Tree.Node winner =
            _joinHeightOne(tournament, winnerClaimer, winnerState, bond);

        uint256 joins = 1;
        Machine.Hash opponentState = Machine.Hash.wrap(bytes32(uint256(1)));
        Tree.Node opponent =
            _joinHeightOne(tournament, vm.addr(1_000), opponentState, bond);
        ++joins;

        Match.Id memory currentMatch = Match.Id(winner, opponent);
        uint256 matchesCreated = 1;
        _assertPooledReserve(
            tournament,
            joins,
            matchesCreated,
            bond,
            refundRecipientBalanceBefore
        );

        for (uint256 i; i < losingCommitments; ++i) {
            Tree.Node nextOpponent;
            Machine.Hash nextOpponentState;
            if (i + 1 < losingCommitments) {
                nextOpponentState = Machine.Hash.wrap(bytes32(uint256(i + 2)));
                nextOpponent = _joinHeightOne(
                    tournament, vm.addr(1_001 + i), nextOpponentState, bond
                );
                ++joins;
                _assertPooledReserve(
                    tournament,
                    joins,
                    matchesCreated,
                    bond,
                    refundRecipientBalanceBefore
                );
            }

            Machine.Hash commitmentOneState =
                i == 0 ? winnerState : opponentState;
            uint256 refundBalanceBefore = address(this).balance;
            _sealHeightOne(tournament, currentMatch, commitmentOneState);
            assertGt(
                address(this).balance,
                refundBalanceBefore,
                "seal should pay a nonzero refund"
            );
            _assertPooledReserve(
                tournament,
                joins,
                matchesCreated,
                bond,
                refundRecipientBalanceBefore
            );

            refundBalanceBefore = address(this).balance;
            tournament.winLeafMatch(
                currentMatch,
                INITIAL_NODE,
                Tree.Node.wrap(Machine.Hash.unwrap(winnerState)),
                new bytes(0)
            );
            assertGt(
                address(this).balance,
                refundBalanceBefore,
                "leaf win should pay a nonzero refund"
            );
            if (i + 1 < losingCommitments) {
                ++matchesCreated;
            }
            _assertPooledReserve(
                tournament,
                joins,
                matchesCreated,
                bond,
                refundRecipientBalanceBefore
            );

            if (i + 1 < losingCommitments) {
                opponent = nextOpponent;
                opponentState = nextOpponentState;
                currentMatch = Match.Id(opponent, winner);
            }
        }

        assertGt(
            address(this).balance,
            refundRecipientBalanceBefore,
            "trace should execute nonzero partial refunds"
        );
        assertEq(joins, uint256(losingCommitments) + 1);

        vm.roll(vm.getBlockNumber() + 1);
        (bool finished, Tree.Node result, Machine.Hash finalState) =
            tournament.arbitrationResult();
        assertTrue(finished);
        assertEq(Tree.Node.unwrap(result), Tree.Node.unwrap(winner));
        assertEq(
            Machine.Hash.unwrap(finalState), Machine.Hash.unwrap(winnerState)
        );

        _recoverAndAssertTerminalAccounting(
            tournament,
            winnerClaimer,
            joins,
            matchesCreated,
            bond,
            refundRecipientBalanceBefore
        );
    }

    function testHeightOneDoubleEliminationPreservesDanglingWinner() public {
        provider.setHeight(1);
        vm.roll(100);
        vm.fee(Bond.WORK_PRICE_CAP);
        vm.txGasPrice(Bond.WORK_PRICE_CAP);

        ITournament tournament =
            factory.instantiate(INITIAL_STATE, IDataProvider(address(0)));
        uint256 bond = tournament.bondValue();
        uint256 refundRecipientBalanceBefore = address(this).balance;

        Machine.Hash stateOne = Machine.Hash.wrap(bytes32(uint256(1)));
        Machine.Hash stateTwo = Machine.Hash.wrap(bytes32(uint256(2)));
        Machine.Hash winnerState = Machine.Hash.wrap(bytes32(uint256(3)));
        Tree.Node one =
            _joinHeightOne(tournament, vm.addr(2_001), stateOne, bond);
        Tree.Node two =
            _joinHeightOne(tournament, vm.addr(2_002), stateTwo, bond);
        address winnerClaimer = vm.addr(2_003);
        Tree.Node winner =
            _joinHeightOne(tournament, winnerClaimer, winnerState, bond);
        uint256 joins = 3;
        uint256 matchesCreated = 1;

        Match.Id memory matchId = Match.Id(one, two);
        uint256 refundBalanceBefore = address(this).balance;
        _sealHeightOne(tournament, matchId, stateOne);
        assertGt(
            address(this).balance,
            refundBalanceBefore,
            "seal should pay a nonzero refund"
        );
        _assertPooledReserve(
            tournament,
            joins,
            matchesCreated,
            bond,
            refundRecipientBalanceBefore
        );

        (Clock.State memory clockOne,) = tournament.getCommitment(one);
        (Clock.State memory clockTwo,) = tournament.getCommitment(two);
        assertEq(
            Time.Instant.unwrap(clockOne.startInstant),
            Time.Instant.unwrap(clockTwo.startInstant)
        );
        assertEq(
            Time.Duration.unwrap(clockOne.allowance),
            Time.Duration.unwrap(clockTwo.allowance)
        );
        vm.roll(
            Time.Instant.unwrap(clockOne.startInstant)
                + Time.Duration.unwrap(clockOne.allowance)
        );
        refundBalanceBefore = address(this).balance;
        tournament.eliminateMatchByTimeout(matchId);
        assertGt(
            address(this).balance,
            refundBalanceBefore,
            "elimination should pay a nonzero refund"
        );
        _assertPooledReserve(
            tournament,
            joins,
            matchesCreated,
            bond,
            refundRecipientBalanceBefore
        );

        (bool finished, Tree.Node result, Machine.Hash finalState) =
            tournament.arbitrationResult();
        assertTrue(finished);
        assertEq(Tree.Node.unwrap(result), Tree.Node.unwrap(winner));
        assertEq(
            Machine.Hash.unwrap(finalState), Machine.Hash.unwrap(winnerState)
        );

        _recoverAndAssertTerminalAccounting(
            tournament,
            winnerClaimer,
            joins,
            matchesCreated,
            bond,
            refundRecipientBalanceBefore
        );
    }

    function _joinHeightOne(
        ITournament tournament,
        address claimer,
        Machine.Hash finalState,
        uint256 bond
    ) internal returns (Tree.Node commitment) {
        Tree.Node finalNode = Tree.Node.wrap(Machine.Hash.unwrap(finalState));
        commitment = INITIAL_NODE.join(finalNode);

        bytes32[] memory finalStateProof = new bytes32[](1);
        finalStateProof[0] = Tree.Node.unwrap(INITIAL_NODE);

        vm.deal(claimer, bond);
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            finalState, finalStateProof, INITIAL_NODE, finalNode
        );
    }

    function _sealHeightOne(
        ITournament tournament,
        Match.Id memory matchId,
        Machine.Hash stateOne
    ) internal {
        Tree.Node finalNodeOne = Tree.Node.wrap(Machine.Hash.unwrap(stateOne));
        bytes32[] memory agreeStateProof = new bytes32[](1);
        // Every helper commitment shares the initial left leaf, so divergence
        // is on the right. The agree proof authenticates the left leaf in
        // commitment one; unlike the join proof, its sibling is the right leaf.
        agreeStateProof[0] = Tree.Node.unwrap(finalNodeOne);

        tournament.sealLeafMatch(
            matchId, INITIAL_NODE, finalNodeOne, INITIAL_STATE, agreeStateProof
        );
    }

    function _assertPooledReserve(
        ITournament tournament,
        uint256 joins,
        uint256 matchesCreated,
        uint256 bond,
        uint256 refundRecipientBalanceBefore
    ) internal view {
        uint256 refunds =
            address(this).balance - refundRecipientBalanceBefore;
        assertEq(address(tournament).balance + refunds, joins * bond);
        assertGe(
            address(tournament).balance, joins * bond - matchesCreated * bond
        );
        assertGe(address(tournament).balance, bond);
    }

    function _recoverAndAssertTerminalAccounting(
        ITournament tournament,
        address winnerClaimer,
        uint256 joins,
        uint256 matchesCreated,
        uint256 bond,
        uint256 refundRecipientBalanceBefore
    ) internal {
        uint256 tournamentBalanceBefore = address(tournament).balance;
        uint256 winnerBalanceBefore = winnerClaimer.balance;
        uint256 burnedBalanceBefore = address(0).balance;
        uint256 refunds = address(this).balance - refundRecipientBalanceBefore;

        assertTrue(tournament.tryRecoveringBond());

        uint256 burned = address(0).balance - burnedBalanceBefore;
        assertEq(winnerClaimer.balance - winnerBalanceBefore, bond);
        assertEq(burned, tournamentBalanceBefore - bond);
        assertEq(address(tournament).balance, 0);
        assertGe(burned, (joins - 1 - matchesCreated) * bond);
        assertEq(
            refunds + burned,
            (joins - 1) * bond,
            "losing reserves must fund successful work or burn"
        );
        assertEq(refunds + bond + burned, joins * bond);
    }

    function _matchWorkAllocation(uint64 height, bool isLeafTournament)
        internal
        pure
        returns (uint256)
    {
        return uint256(height) * Gas.ADVANCE_MATCH
            + Bond.terminalAllocation(isLeafTournament) - Gas.ADVANCE_MATCH;
    }

    function _terminalPath(bool isLeafTournament, uint256 selector)
        internal
        pure
        returns (TerminalPath)
    {
        if (isLeafTournament) {
            return TerminalPath(selector % 5);
        }

        uint256 path = selector % 4;
        return path < 2 ? TerminalPath(path) : TerminalPath(path + 3);
    }

    function _pathAllocation(uint64 height, TerminalPath path)
        internal
        pure
        returns (uint256)
    {
        uint256 advances = (uint256(height) - 1) * Gas.ADVANCE_MATCH;

        if (path == TerminalPath.TIMEOUT_WIN) {
            return advances + Gas.WIN_MATCH_BY_TIMEOUT;
        }
        if (path == TerminalPath.TIMEOUT_ELIMINATION) {
            return advances + Gas.ELIMINATE_MATCH_BY_TIMEOUT;
        }
        if (path == TerminalPath.LEAF_PROOF) {
            return advances + Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH;
        }
        if (path == TerminalPath.LEAF_TIMEOUT_WIN) {
            return advances + Gas.SEAL_LEAF_MATCH + Gas.WIN_MATCH_BY_TIMEOUT;
        }
        if (path == TerminalPath.LEAF_TIMEOUT_ELIMINATION) {
            return
                advances + Gas.SEAL_LEAF_MATCH + Gas.ELIMINATE_MATCH_BY_TIMEOUT;
        }
        if (path == TerminalPath.INNER_WIN) {
            return advances + Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
                + Gas.WIN_INNER_TOURNAMENT;
        }
        return advances + Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            + Gas.ELIMINATE_INNER_TOURNAMENT;
    }
}
