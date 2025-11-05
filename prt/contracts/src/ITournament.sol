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

/// @notice Tournament interface
interface ITournament {
    //
    // Types
    //

    /// @notice Tournament arguments
    /// @param commitmentArgs The commitment arguments
    /// @param level The tournament level
    /// @param levels The number of tournament levels
    /// @param startInstant The start instant of the tournament
    /// @param allowance The time during which the tournament is open
    /// @param maxAllowance The maximum time of a player clock
    /// @param matchEffort The worst-case time to compute a commitment
    /// @param provider The contract that provides input Merkle roots
    /// @dev A root tournament is at level 0.
    /// A single-level tournament has 1 level.
    /// A multi-level tournament has 2 or more levels.
    /// Time is measured in base-layer blocks.
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

    /// @notice Match deletion reason
    /// @param STEP The match was deleted because one of the
    /// commitments was proven wrong through an on-chain
    /// state-transition or "step" function. This only
    /// happens when the match reaches a leaf commitment node
    /// of a leaf tournament (when `level` is `levels - 1`).
    /// @param TIMEOUT The match was deleted because the clock
    /// of at least one of the commitments has timed out.
    /// Note that it is possible that both clocks time out,
    /// in which a third party can delete the match in a way
    /// similar to a garbage-collection routine.
    /// @param CHILD_TOURNAMENT The match was deleted because
    /// of a result of a child tournament. It may be the case
    /// that the child tournament finished without a winner,
    /// in which case both commitments are eliminated, or
    /// with a winner, in which case only one of the commitments
    /// (the loser one in the child tournament) is eliminated.
    enum MatchDeletionReason {
        STEP,
        TIMEOUT,
        CHILD_TOURNAMENT
    }

    /// @notice Winner commitment of a match.
    /// @param NONE Neither commitment won (both #1 and #2 were eliminated)
    /// @param ONE Commitment #1 won (and #2 was eliminated)
    /// @param TWO Commitment #2 won (and #1 was eliminated)
    enum WinnerCommitment {
        NONE,
        ONE,
        TWO
    }

    //
    // Events
    //

    /// @notice A match was created.
    /// @param matchIdHash The match ID hash
    /// @param one The match commitment #1
    /// @param two The match commitment #2
    /// @param leftOfTwo The left child of #2
    event MatchCreated(
        Match.IdHash indexed matchIdHash,
        Tree.Node indexed one,
        Tree.Node indexed two,
        Tree.Node leftOfTwo
    );

    event MatchAdvanced(
        Match.IdHash indexed matchIdHash, Tree.Node otherParent, Tree.Node left
    );

    /// @notice A match was deleted.
    /// @param matchIdHash The match ID hash
    /// @param one The match commitment #1
    /// @param two The match commitment #2
    /// @param reason The match deletion reason
    /// @param winnerCommitment The winner commitment
    event MatchDeleted(
        Match.IdHash indexed matchIdHash,
        Tree.Node indexed one,
        Tree.Node indexed two,
        MatchDeletionReason reason,
        WinnerCommitment winnerCommitment
    );

    /// @notice A commitment has joined.
    /// @param commitment The commitment
    /// @param finalStateHash The final machine state hash
    /// @param submitter The commitment submitter
    event CommitmentJoined(
        Tree.Node commitment,
        Machine.Hash finalStateHash,
        address indexed submitter
    );

    /// @notice Partial bond refund.
    /// @param recipient The recipient
    /// @param value The amount that was refunded
    /// @param success Whether the refund was successful
    /// @param ret The return data of the refund call
    /// @dev In the case of a failed refund (success = false),
    /// the argument `ret` may encode an smart contract error.
    /// A refund should only fail if the recipient account
    /// has any code (which can be an EOA, see EIP-7702).
    event PartialBondRefund(
        address indexed recipient,
        uint256 value,
        bool indexed success,
        bytes ret
    );

    /// @notice An inner tournament was created.
    /// @param matchIdHash The match ID hash
    /// @param childTournament The inner/child tournament
    event NewInnerTournament(
        Match.IdHash indexed matchIdHash, ITournament indexed childTournament
    );

    //
    // Errors
    //

    error InsufficientBond();
    error NoWinner();
    error IncorrectAgreeState(
        Machine.Hash initialState, Machine.Hash agreeState
    );
    error LengthMismatch(uint64 treeHeight, uint64 siblingsLength);
    error CommitmentStateMismatch(Tree.Node received, Tree.Node expected);
    error CommitmentFinalStateMismatch(Tree.Node received, Tree.Node expected);
    error CommitmentProofWrongSize(uint256 received, uint256 expected);
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

    /// @notice Get the amount of Wei necessary to call `joinTournament`.
    /// @return The tournament bond value
    /// @dev The bond value may depend on the tournament level.
    function bondValue() external view returns (uint256);

    /// @notice Try recovering the bond of the winner commitment submitter.
    /// @return Whether the recovery was successful
    function tryRecoveringBond() external returns (bool);

    /// @notice Get the result of the tournament.
    /// @return finished Whether the tournament has finished already
    /// @return winnerCommitment The winner commitment (if finished)
    /// @return finalState The winning final state (if finished)
    function arbitrationResult()
        external
        view
        returns (
            bool finished,
            Tree.Node winnerCommitment,
            Machine.Hash finalState
        );

    /// @notice Join the tournament with a commitment.
    /// @param finalState The final machine state hash
    /// @param proof The proof of the final machine state hash
    /// @param leftNode The commitment left node
    /// @param rightNode The commitment right node
    /// @dev Root tournaments are open to everyone,
    /// while non-root tournaments are open to anyone
    /// whose final state hash matches the one of the two in the parent tournament.
    /// This function must be called while passing a
    /// minimum amount of Wei, given by the `bondValue` view function.
    /// The contract will retain any extra amount.
    function joinTournament(
        Machine.Hash finalState,
        bytes32[] calldata proof,
        Tree.Node leftNode,
        Tree.Node rightNode
    ) external payable;

    /// @notice Advance a running match by one alternating double-bisection step
    /// toward the first conflicting leaf.
    ///
    /// @dev
    /// ROLE & INPUTS FOR THIS STEP
    /// - At this call, the tree stored in `Match.State.otherParent` is the one being
    ///   bisected at height `h`.
    /// - `leftNode` and `rightNode` MUST be the two children of that parent at
    ///   height `h-1`.
    /// - The match logic compares the provided left child with the opposite tree’s
    ///   baseline (kept in state) to decide whether disagreement lies on the left
    ///   or on the right half at height `h`.
    /// - The caller MUST also provide `newLeftNode`/`newRightNode`, which are the
    ///   children of the **chosen half** (left or right) that we descend into. These
    ///   seed the next step after roles flip (alternation).
    ///
    ///
    /// INVARIANTS (enforced by the library)
    /// - Height decreases monotonically toward leaves.
    /// - Exactly one tree is double-bisected per call; roles alternate automatically.
    /// - Node relationships are checked at every step (parent->children, child->children).
    ///
    /// @param matchId        The logical pair of commitments for this match.
    /// @param leftNode       Left child of the parent being bisected at this step (height h-1).
    /// @param rightNode      Right child of the parent being bisected at this step (height h-1).
    /// @param newLeftNode    Left child of the chosen half we descend into (height h-2).
    /// @param newRightNode   Right child of the chosen half we descend into (height h-2).
    ///
    /// @custom:effects Emits `MatchAdvanced`.
    /// @custom:reverts If the match does not exist, cannot be advanced, or any of the
    /// supplied nodes are inconsistent with the parent/child relations for this step.
    function advanceMatch(
        Match.Id calldata matchId,
        Tree.Node leftNode,
        Tree.Node rightNode,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) external;

    /// @notice Win a match by timeout.
    /// @param matchId        The logical pair of commitments for this match.
    /// @param leftNode       Left child of the commitment.
    /// @param rightNode      Right child of the commitment.
    function winMatchByTimeout(
        Match.Id calldata matchId,
        Tree.Node leftNode,
        Tree.Node rightNode
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
    /// @param matchId The pair of commitments that define the match to eliminate.
    function eliminateMatchByTimeout(Match.Id calldata matchId) external;

    /// @notice Seal a match and create an inner tournament.
    /// @param matchId        The logical pair of commitments for this match.
    /// @param leftLeaf       Left child of the parent being bisected at this step (height 1).
    /// @param rightLeaf      Right child of the parent being bisected at this step (height 1).
    /// @param agreeHash      The machine state hash that both commitments agree upon
    /// @param agreeHashProof The proof of the agreed-upon machine state hash
    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata matchId,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeHash,
        bytes32[] calldata agreeHashProof
    ) external;

    /// @notice Win an inner tournament.
    /// @param childTournament The inner/child tournament
    /// @param leftNode        Left child of the winning commitment.
    /// @param rightNode       Right child of the winning commitment.
    function winInnerTournament(
        ITournament childTournament,
        Tree.Node leftNode,
        Tree.Node rightNode
    ) external;

    /// @notice Eliminate an inner tournament.
    /// @param childTournament The inner/child tournament
    function eliminateInnerTournament(ITournament childTournament) external;

    /// @notice Seal a match at height 1 (leaf) by pinpointing the divergent
    /// states and setting the agree state.
    ///
    /// Clock policy:
    /// - During bisection (advanceMatch), only one clock runs at a time.
    /// - After leaf sealing, both clocks are intentionally set to RUNNING to
    ///   incentivize either party to finalize via state-transition proof.
    ///   This accelerates liveness without increasing anyone’s allowance.
    ///
    /// @param matchId        The logical pair of commitments for this match.
    /// @param leftLeaf       Left child of the parent being bisected at this step (height 1).
    /// @param rightLeaf      Right child of the parent being bisected at this step (height 1).
    /// @param agreeHash      The machine state hash that both commitments agree upon
    /// @param agreeHashProof The proof of the agreed-upon machine state hash
    function sealLeafMatch(
        Match.Id calldata matchId,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeHash,
        bytes32[] calldata agreeHashProof
    ) external;

    /// @notice Win a leaf match.
    /// @param matchId         The logical pair of commitments for this match.
    /// @param leftNode        Left child of the winning commitment.
    /// @param rightNode       Right child of the winning commitment.
    /// @param proofs          The state-transition function proofs.
    function winLeafMatch(
        Match.Id calldata matchId,
        Tree.Node leftNode,
        Tree.Node rightNode,
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

    /// @notice Get the tournament arguments.
    function tournamentArguments()
        external
        view
        returns (TournamentArguments memory);

    /// @notice Check whether a match can be won by timeout.
    /// @param matchId The match ID
    function canWinMatchByTimeout(Match.Id calldata matchId)
        external
        view
        returns (bool);

    /// @notice Get the clock and final state of a commitment.
    /// @param commitmentRoot The commitment
    /// @return clock The commitment clock
    /// @return finalState The commited final state
    function getCommitment(Tree.Node commitmentRoot)
        external
        view
        returns (Clock.State memory clock, Machine.Hash finalState);

    /// @notice Get a match state by its ID hash.
    /// @param matchIdHash The match ID hash
    function getMatch(Match.IdHash matchIdHash)
        external
        view
        returns (Match.State memory);

    /// @notice Get the running machine cycle of a match by its ID hash.
    /// @param matchIdHash The match ID hash
    function getMatchCycle(Match.IdHash matchIdHash)
        external
        view
        returns (uint256);

    /// @notice Get tournament-level constants.
    /// @return maxLevel The maximum number of tournament levels
    /// @return level The current tournament level
    /// @return log2step The log2 number of steps between commitment leaves
    /// @return height The height of the commitment tree
    function tournamentLevelConstants()
        external
        view
        returns (uint64 maxLevel, uint64 level, uint64 log2step, uint64 height);

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
