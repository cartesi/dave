// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

interface ITournament {
    //
    // Types
    //

    struct TournamentArguments {
        Commitment.Arguments commitmentArgs;
        uint64 level;
        uint64 levels;
        Time.Instant startInstant;
        Time.Duration allowance;
        Time.Duration maxAllowance;
        Time.Duration matchEffort;
        IDataProvider provider;
    }

    enum MatchDeletionReason {
        STEP,
        TIMEOUT,
        CHILD_TOURNAMENT
    }

    enum WinnerCommitment {
        NONE,
        ONE,
        TWO
    }

    //
    // Events
    //

    event MatchCreated(
        Match.IdHash indexed matchIdHash,
        Tree.Node indexed one,
        Tree.Node indexed two,
        Tree.Node leftOfTwo
    );

    event MatchDeleted(
        Match.IdHash indexed matchIdHash,
        Tree.Node indexed one,
        Tree.Node indexed two,
        MatchDeletionReason reason,
        WinnerCommitment winnerCommitment
    );

    event CommitmentJoined(
        Tree.Node commitment,
        Machine.Hash finalStateHash,
        address indexed caller
    );

    event PartialBondRefund(
        address indexed recipient, uint256 value, bool indexed status, bytes ret
    );

    event NewInnerTournament(
        Match.IdHash indexed matchIdHash, ITournament indexed childTournament
    );

    //
    // Errors
    //

    error InsufficientBond();
    error NoWinner();
    error TournamentIsFinished();
    error TournamentNotFinished();
    error TournamentIsClosed();
    error ReentrancyDetected();
    error WrongChildren(
        uint256 commitment, Tree.Node parent, Tree.Node left, Tree.Node right
    );
    error ClockNotTimedOut();
    error BothClocksHaveNotTimedOut();
    error InvalidContestedFinalState(
        Machine.Hash contestedFinalStateOne,
        Machine.Hash contestedFinalStateTwo,
        Machine.Hash finalState
    );
    error InvalidWinnerCommitment(WinnerCommitment winnerCommitment);
    error TournamentFailedNoWinner();
    error ChildTournamentNotFinished();
    error ChildTournamentCannotBeEliminated();
    error ChildTournamentMustBeEliminated();
    error WrongTournamentWinner(Tree.Node commitmentRoot, Tree.Node winner);
    error InvalidTournamentWinner(Tree.Node winner);
    error WrongFinalState(
        uint256 commitment, Machine.Hash computed, Machine.Hash claimed
    );
    error WrongNodesForStep();
    error NotImplemented();

    //
    // Functions
    //

    function bondValue() external view returns (uint256);

    function tryRecoveringBond() external returns (bool);

    function arbitrationResult()
        external
        view
        returns (
            bool finished,
            Tree.Node winnerCommitment,
            Machine.Hash finalState
        );

    /// @dev root tournaments are open to everyone,
    /// while non-root tournaments are open to anyone
    /// who's final state hash matches the one of the two in the tournament
    /// This function must be called while passing a
    /// minimum amount of Wei, given by the `bondValue` view function.
    /// The contract will retain any extra amount.
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external payable;

    /// @notice Advance a running match by one alternating double-bisection step
    /// toward the first conflicting leaf.
    ///
    /// @dev
    /// ROLE & INPUTS FOR THIS STEP
    /// - At this call, the tree stored in `Match.State.otherParent` is the one being
    ///   bisected at height `h`.
    /// - `_leftNode` and `_rightNode` MUST be the two children of that parent at
    ///   height `h-1`.
    /// - The match logic compares the provided left child with the opposite tree’s
    ///   baseline (kept in state) to decide whether disagreement lies on the left
    ///   or on the right half at height `h`.
    /// - The caller MUST also provide `_newLeftNode`/`_newRightNode`, which are the
    ///   children of the **chosen half** (left or right) that we descend into. These
    ///   seed the next step after roles flip (alternation).
    ///
    ///
    /// INVARIANTS (enforced by the library)
    /// - Height decreases monotonically toward leaves.
    /// - Exactly one tree is double-bisected per call; roles alternate automatically.
    /// - Node relationships are checked at every step (parent→children, child→children).
    ///
    /// @param _matchId        The logical pair of commitments for this match.
    /// @param _leftNode       Left child of the parent being bisected at this step (height h-1).
    /// @param _rightNode      Right child of the parent being bisected at this step (height h-1).
    /// @param _newLeftNode    Left child of the chosen half we descend into (height h-2).
    /// @param _newRightNode   Right child of the chosen half we descend into (height h-2).
    ///
    /// @custom:effects Emits `matchAdvanced` inside `Match.advanceMatch`.
    /// @custom:reverts If the match does not exist, cannot be advanced, or any of the
    /// supplied nodes are inconsistent with the parent/child relations for this step.
    function advanceMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Tree.Node _newLeftNode,
        Tree.Node _newRightNode
    ) external;

    function winMatchByTimeout(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external;

    /// @notice Permissionless cleanup: eliminate a stalled match after both sides
    /// have timed out, i.e., neither party acted within its clock allowance.
    /// @dev
    /// CLOCK MODEL
    /// - During alternating double-bisection steps, exactly one clock runs.
    /// - After leaf sealing (in leaf tournaments), both clocks intentionally run
    ///   to incentivize either party to complete the state-transition proof.
    ///
    /// WHEN IS ELIMINATION ALLOWED?
    /// - Chess-clock model: exactly one side is “on turn” at a time. If a side lets
    ///   its clock reach zero (times out), the *other* side’s clock immediately
    ///   starts running. After leaf sealing, both may be running simultaneously.
    ///   This function allows deletion **only after both** clocks
    ///   have exhausted:
    ///     • Case 1: commitmentOne timed out first AND
    ///               timeSinceTimeout(commitmentOne) >= timeLeft(commitmentTwo)
    ///     • Case 2: commitmentTwo timed out first AND
    ///               timeSinceTimeout(commitmentTwo) >= timeLeft(commitmentOne)
    ///
    /// - Intuition (covers both models): once the first clock hits zero, keep
    ///   counting until the other clock’s remaining budget is fully drained;
    ///   at that point both are out of time and the match can be eliminated.
    ///   If both clocks run and reach zero simultaneously after leaf sealing,
    ///   this condition holds immediately at that block.
    ///
    /// - Occurrence: **Sybil vs. Sybil**. Under the honest-participant assumption,
    ///   the honest side will act before timing out,
    ///   so double-timeout should not occur when an honest commitment participates.
    ///
    /// - Anyone may call this function; it is a public garbage-collection hook.
    ///
    /// @param _matchId The pair of commitments that define the match to eliminate.
    function eliminateMatchByTimeout(Match.Id calldata _matchId) external;

    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external;

    function winInnerTournament(
        ITournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external;

    function eliminateInnerTournament(ITournament _childTournament) external;

    /// @notice Seal a match at height 1 (leaf) by pinpointing the divergent
    /// states and setting the agree state.
    ///
    /// Clock policy:
    /// - During bisection (advanceMatch), only one clock runs at a time.
    /// - After leaf sealing, both clocks are intentionally set to RUNNING to
    ///   incentivize either party to finalize via state-transition proof.
    ///   This accelerates liveness without increasing anyone’s allowance.
    function sealLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external;

    function winLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        bytes calldata proofs
    ) external;

    //
    // View functions
    //

    /// @notice returns whether this inner tournament can be safely eliminated.
    /// @return (bool)
    /// - if the tournament can be eliminated
    function canBeEliminated() external view returns (bool);

    /// @notice get the dangling commitment at current level and then retrieve the winner commitment
    /// @return (bool, Tree.Node, Tree.Node, Clock.State)
    /// - if the tournament is finished
    /// - the contested parent commitment
    /// - the winning inner commitment
    /// - the paused clock of the winning inner commitment
    function innerTournamentWinner()
        external
        view
        returns (bool, Tree.Node, Tree.Node, Clock.State memory);

    function tournamentArguments()
        external
        view
        returns (TournamentArguments memory);

    function canWinMatchByTimeout(Match.Id calldata _matchId)
        external
        view
        returns (bool);

    function getCommitment(Tree.Node _commitmentRoot)
        external
        view
        returns (Clock.State memory, Machine.Hash);

    function getMatch(Match.IdHash _matchIdHash)
        external
        view
        returns (Match.State memory);

    function getMatchCycle(Match.IdHash _matchIdHash)
        external
        view
        returns (uint256);

    function tournamentLevelConstants()
        external
        view
        returns (
            uint64 _maxLevel,
            uint64 _level,
            uint64 _log2step,
            uint64 _height
        );

    //
    // Time view functions
    //

    /// @return bool if the tournament is still open to join
    function isClosed() external view returns (bool);

    /// @return bool if the tournament is over
    function isFinished() external view returns (bool);

    /// @notice returns if and when tournament was finished.
    /// @return (bool, Time.Instant)
    /// - if the tournament can be eliminated
    /// - the time when the tournament was finished
    function timeFinished() external view returns (bool, Time.Instant);
}
