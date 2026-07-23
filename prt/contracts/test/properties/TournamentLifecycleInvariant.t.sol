// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {StdInvariant} from "forge-std-1.9.6/src/StdInvariant.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {
    SmallSingleLevelTournamentFactory
} from "../fixtures/SmallSingleLevelTournament.sol";

/// @dev Stateful model for one small root-and-leaf tournament. The model owns
/// its population, pairing, bisection, clock, and terminal-result transitions;
/// production storage is read only by the assertion functions.
/// Model-legal actions must succeed, while model-illegal lifecycle actions must
/// reject with their exact public error. Inner tournaments, malformed Merkle
/// witnesses, and bond recovery remain in focused suites.
contract TournamentLifecycleHandler is Test {
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint8 internal constant POOL_SIZE = 8;
    uint8 internal constant NO_COMMITMENT = type(uint8).max;

    uint64 internal immutable HEIGHT;
    uint64 internal immutable START_BLOCK;
    uint64 internal immutable MATCH_EFFORT;
    uint64 internal immutable MAX_ALLOWANCE;
    Machine.Hash internal immutable INITIAL_STATE;

    enum TimeoutOutcome {
        NONE,
        ONE_WINS,
        TWO_WINS,
        ELIMINATE_BOTH
    }

    struct GhostClock {
        uint64 allowance;
        uint64 startInstant;
        uint64 initialAllowance;
    }

    struct GhostCommitment {
        bool joined;
        bool live;
        GhostClock clock;
    }

    struct GhostMatch {
        bool active;
        uint8 commitmentOne;
        uint8 commitmentTwo;
        uint8 otherTree;
        uint64 currentHeight;
    }

    struct TimeoutStatus {
        TimeoutOutcome outcome;
        uint64 deferredCharge;
    }

    InspectableTournament internal immutable TOURNAMENT;
    uint256 internal immutable BOND;

    GhostCommitment[POOL_SIZE] private _commitments;
    GhostMatch[] private _matches;

    uint8 private _dangling = NO_COMMITMENT;
    uint256 private _liveCommitmentCount;
    uint256 private _activeMatchCount;
    uint256 private _joinedCount;
    uint256 private _createdCount;
    uint256 private _advancedCount;
    uint256 private _deletedCount;
    uint64 private _lastDeleted;

    uint256 public rejectedDuplicateJoins;
    uint256 public rejectedLateJoins;
    uint256 public rejectedWrongPhaseActions;
    uint256 public rejectedExpiredResponses;
    uint256 public rejectedTimeouts;
    uint256 public rejectedIneligibleProofs;
    uint256 public rejectedDeletedMatches;

    constructor(InspectableTournament tournament) {
        TOURNAMENT = tournament;
        BOND = tournament.bondValue();

        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        assertEq(args.level, 0);
        assertEq(args.levels, 1);
        assertEq(args.commitmentArgs.height, 3);
        assertEq(args.commitmentArgs.log2step, 0);
        assertEq(
            Time.Duration.unwrap(args.allowance),
            Time.Duration.unwrap(args.maxAllowance)
        );
        HEIGHT = args.commitmentArgs.height;
        START_BLOCK = Time.Instant.unwrap(args.startInstant);
        MATCH_EFFORT = Time.Duration.unwrap(args.matchEffort);
        MAX_ALLOWANCE = Time.Duration.unwrap(args.allowance);
        INITIAL_STATE = args.commitmentArgs.initialHash;

        // A collision would invalidate candidate indexing in the ghost model.
        for (uint8 i; i < POOL_SIZE; ++i) {
            Tree.Node root = _tree(i).root();
            assertFalse(root.isZero());
            for (uint8 j; j < i; ++j) {
                assertFalse(root.eq(_tree(j).root()));
            }
        }
    }

    receive() external payable {}

    //
    // Targeted actions
    //

    function join(uint8 rawCandidate) external {
        uint8 candidate = rawCandidate % POOL_SIZE;
        uint64 current = _current();
        if (
            _commitments[candidate].joined
                || current >= START_BLOCK + MAX_ALLOWANCE
        ) {
            return;
        }

        address claimer = _claimer(candidate);
        vm.deal(claimer, BOND);
        vm.prank(claimer);
        _joinCandidate(candidate);

        uint64 allowance = MAX_ALLOWANCE - (current - START_BLOCK);
        GhostCommitment storage commitment = _commitments[candidate];
        commitment.joined = true;
        commitment.live = true;
        commitment.clock = GhostClock({
            allowance: allowance, startInstant: 0, initialAllowance: allowance
        });
        ++_joinedCount;
        ++_liveCommitmentCount;

        _pair(candidate, current);
    }

    function advance(uint256 rawMatch) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        if (ghost.currentHeight <= 1) return;

        uint8 running = _runningCommitment(ghost);
        if (_remaining(_commitments[running].clock, _current()) == 0) {
            return;
        }

        (
            Tree.Node left,
            Tree.Node right,
            Tree.Node newLeft,
            Tree.Node newRight
        ) = _advanceWitness(ghost);

        TOURNAMENT.advanceMatch(_id(ghost), left, right, newLeft, newRight);

        uint64 current = _current();
        _pauseAfterResponse(_commitments[running].clock, current);
        uint8 waiting = running == ghost.commitmentOne
            ? ghost.commitmentTwo
            : ghost.commitmentOne;
        _start(_commitments[waiting].clock, current);

        --ghost.currentHeight;
        ghost.otherTree = waiting;
        ++_advancedCount;
    }

    function sealLeaf(uint256 rawMatch) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        if (ghost.currentHeight != 1) return;

        uint8 running = _runningCommitment(ghost);
        uint64 current = _current();
        if (_remaining(_commitments[running].clock, current) == 0) {
            return;
        }

        (
            Tree.Node leftLeaf,
            Tree.Node rightLeaf,
            Machine.Hash agreeState,
            bytes32[] memory agreeProof
        ) = _sealWitness(ghost);
        TOURNAMENT.sealLeafMatch(
            _id(ghost), leftLeaf, rightLeaf, agreeState, agreeProof
        );

        _pauseAfterResponse(_commitments[running].clock, current);
        _start(_commitments[ghost.commitmentOne].clock, current);
        _start(_commitments[ghost.commitmentTwo].clock, current);

        ghost.currentHeight = 0;
    }

    function proveLeaf(uint256 rawMatch, bool chooseTwo) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        if (ghost.currentHeight != 0) return;

        TimeoutStatus memory timeout = _classify(ghost, _current());
        if (timeout.outcome != TimeoutOutcome.NONE) {
            return;
        }
        uint8 winner = chooseTwo ? ghost.commitmentTwo : ghost.commitmentOne;

        (Tree.Node left, Tree.Node right, bytes memory proof) =
            _proofWitness(ghost, winner);
        TOURNAMENT.winLeafMatch(_id(ghost), left, right, proof);

        _chargeAndPause(_commitments[winner].clock, 0, _current());
        _settleWithWinner(matchIndex, winner, _current());
    }

    function resolveTimeout(uint256 rawMatch) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        TimeoutStatus memory timeout = _classify(ghost, _current());
        if (timeout.outcome == TimeoutOutcome.NONE) return;

        Match.Id memory id = _id(ghost);
        if (timeout.outcome == TimeoutOutcome.ELIMINATE_BOTH) {
            TOURNAMENT.eliminateMatchByTimeout(id);
            _settleWithoutWinner(matchIndex, _current());
            return;
        }

        uint8 winner = timeout.outcome == TimeoutOutcome.ONE_WINS
            ? ghost.commitmentOne
            : ghost.commitmentTwo;
        SmallFullTree.Data memory winnerTree = _tree(winner);
        (Tree.Node left, Tree.Node right) = winnerTree.children(HEIGHT, 0);
        TOURNAMENT.winMatchByTimeout(id, left, right);

        _chargeAndPause(
            _commitments[winner].clock, timeout.deferredCharge, _current()
        );
        _settleWithWinner(matchIndex, winner, _current());
    }

    function elapse(uint64 rawBlocks) external {
        uint64 delta = rawBlocks % 25 + 1;
        vm.roll(block.number + delta);
    }

    //
    // Rejected actions
    //

    function rejectJoin(uint8 rawCandidate, bool joinedWhenClosed) external {
        uint64 current = _current();
        if (current < START_BLOCK + MAX_ALLOWANCE) {
            (bool joinedFound, uint8 joinedCandidate) =
                _selectJoined(rawCandidate);
            if (!joinedFound) return;

            _expectJoinRevert(
                joinedCandidate, ITournament.ClockAlreadyInitialized.selector
            );
            ++rejectedDuplicateJoins;
            return;
        }

        bool candidateFound;
        uint8 candidate;
        if (joinedWhenClosed) {
            (candidateFound, candidate) = _selectJoined(rawCandidate);
        } else {
            (candidateFound, candidate) = _selectUnjoined(rawCandidate);
        }
        if (!candidateFound) return;

        _expectJoinRevert(candidate, ITournament.TournamentIsClosed.selector);
        ++rejectedLateJoins;
    }

    function rejectWrongPhaseAction(uint256 rawMatch, uint8 rawAction)
        external
    {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        uint8 action = rawAction % 3;
        if (action == 0) {
            if (ghost.currentHeight > 1) return;
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.advanceMatch.selector,
                    _id(ghost),
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE
                ),
                ITournament.MatchCannotBeAdvanced.selector
            );
        } else if (action == 1) {
            if (ghost.currentHeight == 1) return;
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.sealLeafMatch.selector,
                    _id(ghost),
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE,
                    Machine.ZERO_STATE,
                    new bytes32[](0)
                ),
                ITournament.MatchCannotBeSealed.selector
            );
        } else {
            if (ghost.currentHeight == 0) return;
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.winLeafMatch.selector,
                    _id(ghost),
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE,
                    new bytes(0)
                ),
                ITournament.MatchIsNotSealed.selector
            );
        }

        ++rejectedWrongPhaseActions;
    }

    function rejectExpiredResponse(uint256 rawMatch) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        if (ghost.currentHeight == 0) return;

        uint8 running = _runningCommitment(ghost);
        if (_remaining(_commitments[running].clock, _current()) != 0) {
            return;
        }

        if (ghost.currentHeight > 1) {
            (
                Tree.Node left,
                Tree.Node right,
                Tree.Node newLeft,
                Tree.Node newRight
            ) = _advanceWitness(ghost);
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.advanceMatch.selector,
                    _id(ghost),
                    left,
                    right,
                    newLeft,
                    newRight
                ),
                ITournament.CannotAdvanceTimedOutClock.selector
            );
        } else {
            (
                Tree.Node leftLeaf,
                Tree.Node rightLeaf,
                Machine.Hash agreeState,
                bytes32[] memory agreeProof
            ) = _sealWitness(ghost);
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.sealLeafMatch.selector,
                    _id(ghost),
                    leftLeaf,
                    rightLeaf,
                    agreeState,
                    agreeProof
                ),
                ITournament.CannotAdvanceTimedOutClock.selector
            );
        }

        ++rejectedExpiredResponses;
    }

    function rejectTimeout(uint256 rawMatch, bool eliminate) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        TimeoutOutcome outcome = _classify(ghost, _current()).outcome;

        if (eliminate) {
            if (outcome == TimeoutOutcome.ELIMINATE_BOTH) return;
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.eliminateMatchByTimeout.selector, _id(ghost)
                ),
                ITournament.AtLeastOneClockHasNotTimedOut.selector
            );
        } else {
            if (
                outcome == TimeoutOutcome.ONE_WINS
                    || outcome == TimeoutOutcome.TWO_WINS
            ) return;
            _expectRevert(
                abi.encodeWithSelector(
                    ITournament.winMatchByTimeout.selector,
                    _id(ghost),
                    Tree.ZERO_NODE,
                    Tree.ZERO_NODE
                ),
                ITournament.NeitherClockHasTimedOut.selector
            );
        }

        ++rejectedTimeouts;
    }

    function rejectIneligibleProof(uint256 rawMatch, bool chooseTwo) external {
        (bool found, uint256 matchIndex) = _selectActive(rawMatch);
        if (!found) return;

        GhostMatch storage ghost = _matches[matchIndex];
        if (ghost.currentHeight != 0) return;

        TimeoutStatus memory timeout = _classify(ghost, _current());
        if (timeout.outcome == TimeoutOutcome.NONE) return;

        uint8 proven = timeout.outcome == TimeoutOutcome.ONE_WINS
            ? ghost.commitmentTwo
            : timeout.outcome == TimeoutOutcome.TWO_WINS
                ? ghost.commitmentOne
                : chooseTwo ? ghost.commitmentTwo : ghost.commitmentOne;
        (Tree.Node left, Tree.Node right, bytes memory proof) =
            _proofWitness(ghost, proven);

        _expectRevert(
            abi.encodeWithSelector(
                ITournament.winLeafMatch.selector,
                _id(ghost),
                left,
                right,
                proof
            ),
            ITournament.CannotAdvanceTimedOutClock.selector
        );
        ++rejectedIneligibleProofs;
    }

    function rejectDeletedMatch(uint256 rawMatch, uint8 rawAction) external {
        (bool found, uint256 matchIndex) = _selectInactive(rawMatch);
        if (!found || TOURNAMENT.isFinished()) return;

        Match.Id memory id = _id(_matches[matchIndex]);
        uint8 action = rawAction % 5;
        bytes memory callData;
        if (action == 0) {
            callData = abi.encodeWithSelector(
                ITournament.advanceMatch.selector,
                id,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE
            );
        } else if (action == 1) {
            callData = abi.encodeWithSelector(
                ITournament.sealLeafMatch.selector,
                id,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE,
                Machine.ZERO_STATE,
                new bytes32[](0)
            );
        } else if (action == 2) {
            callData = abi.encodeWithSelector(
                ITournament.winLeafMatch.selector,
                id,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE,
                new bytes(0)
            );
        } else if (action == 3) {
            callData = abi.encodeWithSelector(
                ITournament.winMatchByTimeout.selector,
                id,
                Tree.ZERO_NODE,
                Tree.ZERO_NODE
            );
        } else {
            callData = abi.encodeWithSelector(
                ITournament.eliminateMatchByTimeout.selector, id
            );
        }

        _expectRevert(callData, ITournament.MatchDoesNotExist.selector);
        ++rejectedDeletedMatches;
    }

    function candidateRoot(uint8 candidate) external view returns (Tree.Node) {
        return _tree(candidate).root();
    }

    function candidateClaimer(uint8 candidate) external pure returns (address) {
        assert(candidate < POOL_SIZE);
        return _claimer(candidate);
    }

    //
    // Invariant assertions
    //

    function assertPopulationAndTopology() external view {
        bool[POOL_SIZE] memory occupied;
        uint256 live;
        uint256 active;

        for (uint256 i; i < _matches.length; ++i) {
            GhostMatch storage ghost = _matches[i];
            if (!ghost.active) continue;

            ++active;
            assertTrue(_commitments[ghost.commitmentOne].live);
            assertTrue(_commitments[ghost.commitmentTwo].live);
            assertFalse(occupied[ghost.commitmentOne]);
            assertFalse(occupied[ghost.commitmentTwo]);
            occupied[ghost.commitmentOne] = true;
            occupied[ghost.commitmentTwo] = true;
        }

        if (_dangling != NO_COMMITMENT) {
            assertTrue(_commitments[_dangling].live);
            assertFalse(occupied[_dangling]);
            occupied[_dangling] = true;
        }

        for (uint8 i; i < POOL_SIZE; ++i) {
            if (_commitments[i].live) {
                ++live;
                assertTrue(occupied[i]);
            } else {
                assertFalse(occupied[i]);
            }
        }

        assertEq(active, _activeMatchCount);
        assertEq(live, _liveCommitmentCount);
        assertEq(live, 2 * active + (_dangling == NO_COMMITMENT ? 0 : 1));

        (
            Tree.Node actualDangling,
            uint256 actualMatches,
            Time.Instant actualLastDeletion
        ) = TOURNAMENT.observedTopology();
        Tree.Node expectedDangling = _dangling == NO_COMMITMENT
            ? Tree.ZERO_NODE
            : _tree(_dangling).root();
        assertEq(
            Tree.Node.unwrap(actualDangling), Tree.Node.unwrap(expectedDangling)
        );
        assertEq(actualMatches, _activeMatchCount);
        assertEq(Time.Instant.unwrap(actualLastDeletion), _lastDeleted);
    }

    function assertMatchesAndCounters() external view {
        assertEq(_matches.length, _createdCount);
        assertEq(TOURNAMENT.getCommitmentJoinedCount(), _joinedCount);
        assertEq(TOURNAMENT.getMatchCreatedCount(), _createdCount);
        assertEq(TOURNAMENT.getMatchAdvancedCount(), _advancedCount);
        assertEq(TOURNAMENT.getMatchDeletedCount(), _deletedCount);
        assertEq(TOURNAMENT.getNewInnerTournamentCount(), 0);
        assertEq(_createdCount - _deletedCount, _activeMatchCount);
        assertLe(_createdCount, _joinedCount == 0 ? 0 : _joinedCount - 1);

        for (uint256 i; i < _matches.length; ++i) {
            GhostMatch storage ghost = _matches[i];
            Match.Id memory id = _id(ghost);
            Match.IdHash idHash = id.hashFromId();
            Match.State memory actual = TOURNAMENT.getMatch(idHash);

            for (uint256 j; j < i; ++j) {
                assertTrue(
                    Match.IdHash.unwrap(idHash)
                        != Match.IdHash.unwrap(_id(_matches[j]).hashFromId())
                );
            }

            if (!ghost.active) {
                assertFalse(actual.exists());
                assertEq(Tree.Node.unwrap(actual.otherParent), bytes32(0));
                assertEq(Tree.Node.unwrap(actual.leftNode), bytes32(0));
                assertEq(Tree.Node.unwrap(actual.rightNode), bytes32(0));
                assertEq(actual.runningLeafPosition, 0);
                assertEq(actual.currentHeight, 0);
                continue;
            }

            assertTrue(actual.exists());
            assertEq(actual.currentHeight, ghost.currentHeight);

            uint256 firstDivergence = _divergence(ghost);
            if (ghost.currentHeight == 0) {
                assertEq(ghost.currentHeight, 0);
                assertEq(actual.runningLeafPosition, firstDivergence);
                Tree.Node expectedAgree = firstDivergence == 0
                    ? Tree.Node.wrap(Machine.Hash.unwrap(INITIAL_STATE))
                    : _tree(ghost.commitmentOne).leaf(firstDivergence - 1);
                assertTrue(actual.otherParent.eq(expectedAgree));

                // Height three leaves commitment one as the final responder.
                // The selected leaf slot depends only on divergence parity.
                Tree.Node oneLeaf =
                    _tree(ghost.commitmentOne).leaf(firstDivergence);
                Tree.Node twoLeaf =
                    _tree(ghost.commitmentTwo).leaf(firstDivergence);
                Tree.Node expectedLeft =
                    firstDivergence % 2 == 0 ? twoLeaf : oneLeaf;
                Tree.Node expectedRight =
                    firstDivergence % 2 == 0 ? oneLeaf : twoLeaf;
                assertTrue(actual.leftNode.eq(expectedLeft));
                assertTrue(actual.rightNode.eq(expectedRight));
            } else {
                uint256 expectedPosition = firstDivergence
                    >> ghost.currentHeight << ghost.currentHeight;
                assertEq(actual.runningLeafPosition, expectedPosition);
                uint8 expectedOther = (HEIGHT - ghost.currentHeight) % 2 == 0
                    ? ghost.commitmentOne
                    : ghost.commitmentTwo;
                assertEq(ghost.otherTree, expectedOther);

                uint8 waiting = expectedOther == ghost.commitmentOne
                    ? ghost.commitmentTwo
                    : ghost.commitmentOne;
                uint256 nodeIndex = firstDivergence >> ghost.currentHeight;
                assertTrue(
                    actual.otherParent
                        .eq(
                            _tree(expectedOther)
                                .node(ghost.currentHeight, nodeIndex)
                        )
                );
                (Tree.Node expectedLeft, Tree.Node expectedRight) =
                    _tree(waiting).children(ghost.currentHeight, nodeIndex);
                assertTrue(actual.leftNode.eq(expectedLeft));
                assertTrue(actual.rightNode.eq(expectedRight));
            }
        }
    }

    function assertClocksAndClaimers() external view {
        uint256 runningInMatches;
        uint256 sealedMatches;

        for (uint8 i; i < POOL_SIZE; ++i) {
            SmallFullTree.Data memory tree = _tree(i);
            Tree.Node root = tree.root();
            (Clock.State memory actual, Machine.Hash finalState) =
                TOURNAMENT.getCommitment(root);
            GhostCommitment storage ghost = _commitments[i];

            if (!ghost.joined) {
                assertEq(Time.Duration.unwrap(actual.allowance), 0);
                assertEq(Time.Instant.unwrap(actual.startInstant), 0);
                assertEq(Machine.Hash.unwrap(finalState), bytes32(0));
                assertEq(TOURNAMENT.observedClaimer(root), address(0));
                continue;
            }

            assertGt(ghost.clock.allowance, 0);
            assertLe(ghost.clock.allowance, ghost.clock.initialAllowance);
            assertEq(
                Time.Duration.unwrap(actual.allowance), ghost.clock.allowance
            );
            assertEq(
                Time.Instant.unwrap(actual.startInstant),
                ghost.clock.startInstant
            );
            assertEq(
                Machine.Hash.unwrap(finalState),
                Machine.Hash.unwrap(tree.finalState())
            );
            assertEq(
                TOURNAMENT.observedClaimer(root),
                ghost.live ? _claimer(i) : address(0)
            );
        }

        for (uint256 i; i < _matches.length; ++i) {
            GhostMatch storage ghost = _matches[i];
            if (!ghost.active) continue;

            bool oneRunning =
                _commitments[ghost.commitmentOne].clock.startInstant != 0;
            bool twoRunning =
                _commitments[ghost.commitmentTwo].clock.startInstant != 0;
            runningInMatches += (oneRunning ? 1 : 0) + (twoRunning ? 1 : 0);

            if (ghost.currentHeight == 0) {
                ++sealedMatches;
                assertTrue(oneRunning && twoRunning);
                assertEq(
                    _commitments[ghost.commitmentOne].clock.startInstant,
                    _commitments[ghost.commitmentTwo].clock.startInstant
                );
            } else {
                assertTrue(oneRunning != twoRunning);
                assertEq(ghost.otherTree == ghost.commitmentOne, oneRunning);
            }
        }

        // Every bisection has one running clock and every sealed leaf has two.
        // Thus at least floor(live / 2) run; when live is odd, the one extra
        // commitment is the unmatched, paused dangling commitment.
        assertEq(runningInMatches, _activeMatchCount + sealedMatches);
        assertEq(_activeMatchCount, _liveCommitmentCount / 2);
        if (_dangling != NO_COMMITMENT) {
            assertEq(_commitments[_dangling].clock.startInstant, 0);
        }
    }

    function assertTerminalResult() external view {
        bool expectedClosed = block.number >= START_BLOCK + MAX_ALLOWANCE;
        bool expectedFinished = expectedClosed && _activeMatchCount == 0;
        assertEq(TOURNAMENT.isClosed(), expectedClosed);
        assertEq(TOURNAMENT.isFinished(), expectedFinished);

        (bool timeIsFinal, Time.Instant timeFinished) =
            TOURNAMENT.timeFinished();
        assertEq(timeIsFinal, expectedFinished);
        if (expectedFinished) {
            uint64 closedAt = START_BLOCK + MAX_ALLOWANCE;
            uint64 expectedTime =
                _lastDeleted > closedAt ? _lastDeleted : closedAt;
            assertEq(Time.Instant.unwrap(timeFinished), expectedTime);
        } else {
            assertEq(Time.Instant.unwrap(timeFinished), 0);
        }

        (bool success, bytes memory result) = address(TOURNAMENT)
            .staticcall(
                abi.encodeWithSelector(ITournament.arbitrationResult.selector)
            );
        if (!expectedFinished) {
            assertTrue(success);
            (bool finished, Tree.Node winner, Machine.Hash finalState) =
                abi.decode(result, (bool, Tree.Node, Machine.Hash));
            assertFalse(finished);
            assertTrue(winner.isZero());
            assertEq(Machine.Hash.unwrap(finalState), bytes32(0));
        } else if (_dangling == NO_COMMITMENT) {
            assertFalse(success);
            assertGe(result.length, 4);
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(result, 32))
            }
            assertEq(selector, ITournament.TournamentFailedNoWinner.selector);
        } else {
            assertTrue(success);
            (bool finished, Tree.Node winner, Machine.Hash finalState) =
                abi.decode(result, (bool, Tree.Node, Machine.Hash));
            SmallFullTree.Data memory tree = _tree(_dangling);
            assertTrue(finished);
            assertTrue(winner.eq(tree.root()));
            assertEq(
                Machine.Hash.unwrap(finalState),
                Machine.Hash.unwrap(tree.finalState())
            );
            assertEq(TOURNAMENT.observedClaimer(winner), _claimer(_dangling));
        }
    }

    //
    // Independent model transitions
    //

    function _pair(uint8 candidate, uint64 current) private {
        if (_dangling == NO_COMMITMENT) {
            _dangling = candidate;
            return;
        }

        uint8 one = _dangling;
        _dangling = NO_COMMITMENT;
        _matches.push(
            GhostMatch({
                active: true,
                commitmentOne: one,
                commitmentTwo: candidate,
                otherTree: one,
                currentHeight: HEIGHT
            })
        );
        _start(_commitments[one].clock, current);
        ++_activeMatchCount;
        ++_createdCount;
    }

    function _settleWithWinner(uint256 matchIndex, uint8 winner, uint64 current)
        private
    {
        GhostMatch storage ghost = _matches[matchIndex];
        uint8 loser = winner == ghost.commitmentOne
            ? ghost.commitmentTwo
            : ghost.commitmentOne;
        _commitments[loser].live = false;
        --_liveCommitmentCount;

        _pair(winner, current);
        _deleteMatch(matchIndex, current);
    }

    function _settleWithoutWinner(uint256 matchIndex, uint64 current) private {
        GhostMatch storage ghost = _matches[matchIndex];
        _commitments[ghost.commitmentOne].live = false;
        _commitments[ghost.commitmentTwo].live = false;
        _liveCommitmentCount -= 2;
        _deleteMatch(matchIndex, current);
    }

    function _deleteMatch(uint256 matchIndex, uint64 current) private {
        assertTrue(_matches[matchIndex].active);
        _matches[matchIndex].active = false;
        --_activeMatchCount;
        ++_deletedCount;
        _lastDeleted = current;
    }

    function _pauseAfterResponse(GhostClock storage clock, uint64 current)
        private
    {
        assertTrue(clock.startInstant != 0);
        uint64 elapsed = current - clock.startInstant;
        assertLt(elapsed, clock.allowance);
        uint64 charge = elapsed > MATCH_EFFORT ? elapsed - MATCH_EFFORT : 0;
        uint64 previous = clock.allowance;
        clock.allowance -= charge;
        clock.startInstant = 0;
        assertLe(clock.allowance, previous);
        assertGt(clock.allowance, 0);
    }

    function _chargeAndPause(
        GhostClock storage clock,
        uint64 charge,
        uint64 current
    ) private {
        uint64 previous = clock.allowance;
        uint64 remaining = _remaining(clock, current);
        assertGt(remaining, charge);
        clock.allowance = remaining - charge;
        clock.startInstant = 0;
        assertLe(clock.allowance, previous);
    }

    function _start(GhostClock storage clock, uint64 current) private {
        assertGt(clock.allowance, 0);
        assertEq(clock.startInstant, 0);
        assertGt(current, 0);
        clock.startInstant = current;
    }

    function _classify(GhostMatch storage ghost, uint64 current)
        private
        view
        returns (TimeoutStatus memory)
    {
        // Express timeout policy directly from the two raw clock balances.
        // MatchClocks.t.sol owns the exhaustive truth table; the directed lifecycle
        // traces below pin both winners and the inclusive equality boundary.
        GhostClock storage one = _commitments[ghost.commitmentOne].clock;
        GhostClock storage two = _commitments[ghost.commitmentTwo].clock;
        uint64 remainingOne = _remaining(one, current);
        uint64 remainingTwo = _remaining(two, current);

        if (remainingOne == 0) {
            if (remainingTwo == 0) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH, deferredCharge: 0
                });
            }

            uint64 overdueOne = current - one.startInstant - one.allowance;
            uint64 deferredCharge = two.startInstant == 0 ? overdueOne : 0;
            if (remainingTwo > deferredCharge) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.TWO_WINS,
                    deferredCharge: deferredCharge
                });
            } else {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH, deferredCharge: 0
                });
            }
        } else if (remainingTwo == 0) {
            uint64 overdueTwo = current - two.startInstant - two.allowance;
            uint64 deferredCharge = one.startInstant == 0 ? overdueTwo : 0;
            if (remainingOne > deferredCharge) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ONE_WINS,
                    deferredCharge: deferredCharge
                });
            } else {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH, deferredCharge: 0
                });
            }
        } else {
            return
                TimeoutStatus({outcome: TimeoutOutcome.NONE, deferredCharge: 0});
        }
    }

    function _remaining(GhostClock storage clock, uint64 current)
        private
        view
        returns (uint64)
    {
        if (clock.startInstant == 0) return clock.allowance;
        uint64 elapsed = current - clock.startInstant;
        return elapsed >= clock.allowance ? 0 : clock.allowance - elapsed;
    }

    //
    // Witness and selection helpers
    //

    function _expectJoinRevert(uint8 candidate, bytes4 expected) private {
        SmallFullTree.Data memory tree = _tree(candidate);
        (Tree.Node left, Tree.Node right) = tree.children(HEIGHT, 0);
        _expectRevert(
            abi.encodeWithSelector(
                ITournament.joinTournament.selector,
                tree.finalState(),
                tree.finalProof(),
                left,
                right
            ),
            expected,
            BOND
        );
    }

    function _expectRevert(bytes memory callData, bytes4 expected) private {
        _expectRevert(callData, expected, 0);
    }

    function _expectRevert(
        bytes memory callData,
        bytes4 expected,
        uint256 value
    ) private {
        (bool success, bytes memory result) =
            address(TOURNAMENT).call{value: value}(callData);
        assertFalse(success);
        assertGe(result.length, 4);

        bytes4 actual;
        assembly ("memory-safe") {
            actual := mload(add(result, 32))
        }
        assertEq(actual, expected);
    }

    function _joinCandidate(uint8 candidate) private {
        SmallFullTree.Data memory tree = _tree(candidate);
        (Tree.Node left, Tree.Node right) = tree.children(HEIGHT, 0);
        TOURNAMENT.joinTournament{value: BOND}(
            tree.finalState(), tree.finalProof(), left, right
        );
    }

    function _advanceWitness(GhostMatch storage ghost)
        private
        view
        returns (
            Tree.Node left,
            Tree.Node right,
            Tree.Node newLeft,
            Tree.Node newRight
        )
    {
        SmallFullTree.Data memory revealingTree = _tree(ghost.otherTree);
        uint256 divergence = _divergence(ghost);
        uint256 nodeIndex = divergence >> ghost.currentHeight;
        (left, right) = revealingTree.children(ghost.currentHeight, nodeIndex);
        uint256 childIndex = divergence >> (ghost.currentHeight - 1);
        (newLeft, newRight) =
            revealingTree.children(ghost.currentHeight - 1, childIndex);
    }

    function _sealWitness(GhostMatch storage ghost)
        private
        view
        returns (
            Tree.Node leftLeaf,
            Tree.Node rightLeaf,
            Machine.Hash agreeState,
            bytes32[] memory agreeProof
        )
    {
        SmallFullTree.Data memory revealingTree = _tree(ghost.otherTree);
        uint256 divergence = _divergence(ghost);
        uint256 nodeIndex = divergence >> 1;
        (leftLeaf, rightLeaf) = revealingTree.children(1, nodeIndex);
        (agreeState, agreeProof) = _agreeWitness(ghost, divergence);
    }

    function _proofWitness(GhostMatch storage ghost, uint8 proven)
        private
        view
        returns (Tree.Node left, Tree.Node right, bytes memory proof)
    {
        assertTrue(
            proven == ghost.commitmentOne || proven == ghost.commitmentTwo
        );
        SmallFullTree.Data memory tree = _tree(proven);
        (left, right) = tree.children(HEIGHT, 0);
        proof = abi.encode(Tree.Node.unwrap(tree.leaf(_divergence(ghost))));
    }

    function _selectActive(uint256 rawMatch)
        private
        view
        returns (bool found, uint256 matchIndex)
    {
        if (_activeMatchCount == 0) return (false, 0);
        uint256 target = rawMatch % _activeMatchCount;
        for (uint256 i; i < _matches.length; ++i) {
            if (!_matches[i].active) continue;
            if (target == 0) return (true, i);
            --target;
        }
        assert(false);
        return (false, 0);
    }

    function _selectInactive(uint256 rawMatch)
        private
        view
        returns (bool found, uint256 matchIndex)
    {
        uint256 inactive = _matches.length - _activeMatchCount;
        if (inactive == 0) return (false, 0);
        uint256 target = rawMatch % inactive;
        for (uint256 i; i < _matches.length; ++i) {
            if (_matches[i].active) continue;
            if (target == 0) return (true, i);
            --target;
        }
        assert(false);
        return (false, 0);
    }

    function _selectJoined(uint8 rawCandidate)
        private
        view
        returns (bool found, uint8 candidate)
    {
        if (_joinedCount == 0) return (false, 0);
        uint256 target = uint256(rawCandidate) % _joinedCount;
        for (uint8 i; i < POOL_SIZE; ++i) {
            if (!_commitments[i].joined) continue;
            if (target == 0) return (true, i);
            --target;
        }
        assert(false);
        return (false, 0);
    }

    function _selectUnjoined(uint8 rawCandidate)
        private
        view
        returns (bool found, uint8 candidate)
    {
        uint256 unjoined = POOL_SIZE - _joinedCount;
        if (unjoined == 0) return (false, 0);
        uint256 target = uint256(rawCandidate) % unjoined;
        for (uint8 i; i < POOL_SIZE; ++i) {
            if (_commitments[i].joined) continue;
            if (target == 0) return (true, i);
            --target;
        }
        assert(false);
        return (false, 0);
    }

    function _runningCommitment(GhostMatch storage ghost)
        private
        view
        returns (uint8)
    {
        assertGt(ghost.currentHeight, 0);
        uint8 running = ghost.otherTree;
        assertTrue(
            _commitments[running].clock.startInstant != 0
                && _commitments[running == ghost.commitmentOne
                            ? ghost.commitmentTwo
                            : ghost.commitmentOne].clock
                    .startInstant == 0
        );
        return running;
    }

    function _divergence(GhostMatch storage ghost)
        private
        view
        returns (uint256 position)
    {
        bool found;
        (found, position) = _tree(ghost.commitmentOne)
            .firstDivergence(_tree(ghost.commitmentTwo));
        assertTrue(found);
    }

    function _agreeWitness(GhostMatch storage ghost, uint256 divergence)
        private
        view
        returns (Machine.Hash agreeState, bytes32[] memory proof)
    {
        assertEq(_divergence(ghost), divergence);
        if (divergence == 0) {
            return (INITIAL_STATE, new bytes32[](0));
        }

        // Match.sealDivergence verifies nonzero agree positions against commitment
        // one for an odd-height tree. Derive that owner from HEIGHT here rather
        // than from the current responder.
        uint8 proofOwner =
            HEIGHT % 2 == 1 ? ghost.commitmentOne : ghost.commitmentTwo;
        SmallFullTree.Data memory tree = _tree(proofOwner);
        agreeState = tree.leaf(divergence - 1).toMachineHash();
        proof = tree.proof(divergence - 1);
    }

    function _id(GhostMatch storage ghost)
        private
        view
        returns (Match.Id memory)
    {
        return Match.Id({
            commitmentOne: _tree(ghost.commitmentOne).root(),
            commitmentTwo: _tree(ghost.commitmentTwo).root()
        });
    }

    function _tree(uint8 candidate)
        private
        view
        returns (SmallFullTree.Data memory)
    {
        assert(candidate < POOL_SIZE);
        Tree.Node[] memory leaves = new Tree.Node[](1 << HEIGHT);
        // Candidate bits select discriminator leaves in both halves and at
        // position zero; the final leaf makes each reported final state unique.
        // MatchBisectionParityTest owns exhaustive position/path coverage.
        for (uint256 i; i < leaves.length; ++i) {
            uint256 value = 0x1000 + 2 * i;
            if (
                i == 0 && (candidate & 1) != 0 || i == 2 && (candidate & 2) != 0
                    || i == 5 && (candidate & 4) != 0
            ) {
                ++value;
            }
            if (i == leaves.length - 1) {
                value = 0x2000 + candidate;
            }
            leaves[i] = Tree.Node.wrap(bytes32(value));
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _claimer(uint8 candidate) private pure returns (address) {
        return address(uint160(0x1000 + candidate));
    }

    function _current() private view returns (uint64) {
        assert(block.number <= type(uint64).max);
        return uint64(block.number);
    }
}

abstract contract TournamentLifecycleTestBase is Test {
    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant MATCH_EFFORT = 5;
    uint64 internal constant MAX_ALLOWANCE = 200;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));

    InspectableTournament internal tournament;
    TournamentLifecycleHandler internal handler;

    function _setUpLifecycle() internal {
        vm.roll(START_BLOCK);
        SmallSingleLevelTournamentFactory factory = new SmallSingleLevelTournamentFactory(
            Time.Duration.wrap(MATCH_EFFORT), Time.Duration.wrap(MAX_ALLOWANCE)
        );
        tournament = InspectableTournament(
            address(
                factory.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        handler = new TournamentLifecycleHandler(tournament);
        vm.deal(address(handler), 100 ether);

        // Begin with two matches whose first divergences occupy different
        // halves. Random joins then exercise dangling and re-pairing paths.
        handler.join(0);
        handler.join(4);
        handler.join(1);
        handler.join(3);
    }

    function _assertLifecycle() internal view {
        handler.assertPopulationAndTopology();
        handler.assertMatchesAndCounters();
        handler.assertClocksAndClaimers();
        handler.assertTerminalResult();
    }

    function _proveFirstActiveMatch() internal {
        handler.advance(0);
        handler.advance(0);
        handler.sealLeaf(0);
        handler.proveLeaf(0, false);
        _assertLifecycle();
    }

    function _elapseBy(uint64 blocks_) internal {
        while (blocks_ > 25) {
            handler.elapse(24);
            blocks_ -= 25;
        }
        if (blocks_ > 0) {
            handler.elapse(blocks_ - 1);
        }
    }
}

contract TournamentLifecycleInvariantTest is
    StdInvariant,
    TournamentLifecycleTestBase
{
    function setUp() public {
        _setUpLifecycle();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = TournamentLifecycleHandler.join.selector;
        selectors[1] = TournamentLifecycleHandler.advance.selector;
        selectors[2] = TournamentLifecycleHandler.sealLeaf.selector;
        selectors[3] = TournamentLifecycleHandler.proveLeaf.selector;
        selectors[4] = TournamentLifecycleHandler.resolveTimeout.selector;
        selectors[5] = TournamentLifecycleHandler.elapse.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// @dev Handler preconditions return without calling. A production revert
    /// after a model-legal call therefore fails the campaign.
    function invariantLifecycle() public view {
        _assertLifecycle();
    }
}

contract TournamentLifecycleRejectionInvariantTest is
    StdInvariant,
    TournamentLifecycleTestBase
{
    function setUp() public {
        _setUpLifecycle();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = TournamentLifecycleHandler.join.selector;
        selectors[1] = TournamentLifecycleHandler.advance.selector;
        selectors[2] = TournamentLifecycleHandler.sealLeaf.selector;
        selectors[3] = TournamentLifecycleHandler.proveLeaf.selector;
        selectors[4] = TournamentLifecycleHandler.resolveTimeout.selector;
        selectors[5] = TournamentLifecycleHandler.elapse.selector;
        selectors[6] = TournamentLifecycleHandler.rejectJoin.selector;
        selectors[7] =
        TournamentLifecycleHandler.rejectWrongPhaseAction.selector;
        selectors[8] = TournamentLifecycleHandler.rejectExpiredResponse.selector;
        selectors[9] = TournamentLifecycleHandler.rejectTimeout.selector;
        selectors[10] =
        TournamentLifecycleHandler.rejectIneligibleProof.selector;
        selectors[11] = TournamentLifecycleHandler.rejectDeletedMatch.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    /// @dev Legal calls must succeed. Rejection actions use low-level calls to
    /// require the model-selected public error without mutating ghost state.
    function invariantLifecycleRejectsIllegalActions() public view {
        _assertLifecycle();
    }
}

contract TournamentLifecycleTraceTest is TournamentLifecycleTestBase {
    function setUp() public {
        _setUpLifecycle();
    }

    function testDeterministicWinnerRePairing() public {
        _proveFirstActiveMatch();
        _proveFirstActiveMatch();
        _proveFirstActiveMatch();

        _elapseBy(200);

        _assertLifecycle();
        assertTrue(tournament.isFinished());
        assertEq(tournament.getMatchCreatedCount(), 3);
        assertEq(tournament.getMatchDeletedCount(), 3);
    }

    function testDeterministicDoubleEliminationFailure() public {
        // At 400 elapsed blocks, the running side's overdue time equals the
        // waiting side's allowance, so the inclusive boundary eliminates both.
        _elapseBy(400);
        handler.resolveTimeout(0);
        handler.resolveTimeout(0);

        _assertLifecycle();
        assertTrue(tournament.isFinished());
        assertEq(tournament.getMatchDeletedCount(), 2);
    }

    function testDeterministicActiveTimeoutTwoWinsAtDeadline() public {
        _elapseBy(200);
        handler.resolveTimeout(0);

        _assertLifecycle();
        assertEq(tournament.getMatchDeletedCount(), 1);
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(0)), address(0)
        );
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(4)),
            handler.candidateClaimer(4)
        );
    }

    function testDeterministicActiveTimeoutOneWinsAfterAdvance() public {
        handler.advance(0);
        _elapseBy(200);
        handler.resolveTimeout(0);

        _assertLifecycle();
        assertEq(tournament.getMatchDeletedCount(), 1);
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(0)),
            handler.candidateClaimer(0)
        );
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(4)), address(0)
        );
    }

    function testDeterministicSealedTimeoutTwoWins() public {
        _elapseBy(10);
        handler.advance(0);
        _elapseBy(10);
        handler.advance(0);
        _elapseBy(10);
        handler.sealLeaf(0);

        // Commitment one has 190 blocks and commitment two has 195. At the
        // former's exact deadline, commitment two wins with five blocks left.
        _elapseBy(190);
        handler.resolveTimeout(0);

        _assertLifecycle();
        assertEq(tournament.getMatchDeletedCount(), 1);
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(0)), address(0)
        );
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(4)),
            handler.candidateClaimer(4)
        );
    }

    function testDeterministicSealedTimeoutTieEliminatesBoth() public {
        handler.advance(0);
        handler.advance(0);
        handler.sealLeaf(0);
        _elapseBy(200);
        handler.resolveTimeout(0);

        _assertLifecycle();
        assertEq(tournament.getMatchDeletedCount(), 1);
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(0)), address(0)
        );
        assertEq(
            tournament.observedClaimer(handler.candidateRoot(4)), address(0)
        );
    }
}

contract TournamentLifecycleRejectionTraceTest is TournamentLifecycleTestBase {
    function setUp() public {
        _setUpLifecycle();
    }

    function testRejectsDuplicateAndLateJoins() public {
        handler.rejectJoin(0, false);
        assertEq(handler.rejectedDuplicateJoins(), 1);

        vm.roll(START_BLOCK + MAX_ALLOWANCE);
        handler.rejectJoin(0, false);
        handler.rejectJoin(0, true);
        assertEq(handler.rejectedLateJoins(), 2);
        _assertLifecycle();
    }

    function testRejectsWrongPhasesAndPrematureTimeouts() public {
        handler.rejectWrongPhaseAction(0, 1);
        handler.rejectWrongPhaseAction(0, 2);
        handler.rejectTimeout(0, false);
        handler.rejectTimeout(0, true);

        handler.advance(0);
        handler.advance(0);
        handler.rejectWrongPhaseAction(0, 0);
        handler.sealLeaf(0);
        handler.rejectWrongPhaseAction(0, 0);
        handler.rejectWrongPhaseAction(0, 1);

        assertEq(handler.rejectedWrongPhaseActions(), 5);
        assertEq(handler.rejectedTimeouts(), 2);
        _assertLifecycle();
    }

    function testRejectsExpiredAdvance() public {
        vm.roll(START_BLOCK + MAX_ALLOWANCE);
        handler.rejectExpiredResponse(0);

        assertEq(handler.rejectedExpiredResponses(), 1);
        _assertLifecycle();
    }

    function testRejectsExpiredSeal() public {
        handler.advance(0);
        handler.advance(0);
        vm.roll(START_BLOCK + MAX_ALLOWANCE);
        handler.rejectExpiredResponse(0);

        assertEq(handler.rejectedExpiredResponses(), 1);
        _assertLifecycle();
    }

    function testRejectsTimedLoserProofAndElimination() public {
        vm.roll(START_BLOCK + 10);
        handler.advance(0);
        vm.roll(START_BLOCK + 20);
        handler.advance(0);
        vm.roll(START_BLOCK + 30);
        handler.sealLeaf(0);

        // Side one has 190 blocks and side two has 195. At side one's
        // deadline only side two may win, and proof settlement is too late.
        vm.roll(START_BLOCK + 220);
        handler.rejectIneligibleProof(0, false);
        handler.rejectTimeout(0, true);

        assertEq(handler.rejectedIneligibleProofs(), 1);
        assertEq(handler.rejectedTimeouts(), 1);
        _assertLifecycle();
    }

    function testRejectsProofAndWinDuringDoubleElimination() public {
        handler.advance(0);
        handler.advance(0);
        handler.sealLeaf(0);
        vm.roll(START_BLOCK + MAX_ALLOWANCE);

        handler.rejectIneligibleProof(0, false);
        handler.rejectTimeout(0, false);

        assertEq(handler.rejectedIneligibleProofs(), 1);
        assertEq(handler.rejectedTimeouts(), 1);
        _assertLifecycle();
    }

    function testRejectsEveryProgressPathForADeletedMatch() public {
        _proveFirstActiveMatch();
        for (uint8 action; action < 5; ++action) {
            handler.rejectDeletedMatch(0, action);
        }

        assertEq(handler.rejectedDeletedMatches(), 5);
        _assertLifecycle();
    }
}
