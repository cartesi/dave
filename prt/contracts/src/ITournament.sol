// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
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

    /// @notice Dispute information from a parent match.
    /// @dev For non-root tournaments (level > 0), contains the two contested commitments
    ///      and final states from the parent match that created this tournament.
    ///      For root tournaments (level == 0), all fields are zero.
    struct NestedDispute {
        Tree.Node contestedCommitmentOne;
        Machine.Hash contestedFinalStateOne;
        Tree.Node contestedCommitmentTwo;
        Machine.Hash contestedFinalStateTwo;
    }

    /// @notice Tournament arguments
    /// @param commitmentArgs The commitment arguments
    /// @param level The tournament level
    /// @param levels The number of tournament levels
    /// @param startInstant The start instant of the tournament
    /// @param allowance The time during which the tournament is open
    /// @param responseBudget The maximum elapsed-time discount earned by each
    /// successful bisection response, including the final sealing response
    /// @param provider The contract that provides input Merkle roots
    /// @param nestedDispute Dispute information from parent match (zero for root tournaments)
    /// @param stateTransition State transition contract, used by leaf-level operations
    /// @param tournamentFactory Multi-level factory address (cast to IMultiLevelTournamentFactory when needed), used by non-leaf operations when instantiating inner tournaments
    /// @dev A root tournament is at level 0.
    /// A single-level tournament has 1 level.
    /// A multi-level tournament has 2 or more levels.
    /// Time is measured by the contract time source, currently `block.number`.
    /// For root tournaments (level == 0), nestedDispute fields are zero.
    struct TournamentArguments {
        Commitment.Arguments commitmentArgs;
        uint64 level;
        uint64 levels;
        Time.Instant startInstant;
        Time.Duration allowance;
        Time.Duration responseBudget;
        IDataProvider provider;
        NestedDispute nestedDispute;
        IStateTransition stateTransition;
        address tournamentFactory; // Cast to IMultiLevelTournamentFactory when needed to avoid circular dependency
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

    /// @notice A match has advanced.
    /// @param matchIdHash The match ID hash
    /// @param otherParent The parent the next responder must reveal
    /// @param leftNode The waiting side's left child after the advance
    /// @dev Each advance selects the left half when the two left children differ,
    /// otherwise the right half, then swaps revealing and waiting roles. The
    /// event exposes the post-advance revealing parent and waiting left child.
    /// The waiting right child is unnecessary for selecting the next branch,
    /// which depends only on left-child equality; the full raw state remains
    /// available through `getMatch`.
    event MatchAdvanced(
        Match.IdHash indexed matchIdHash,
        Tree.Node otherParent,
        Tree.Node leftNode
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

    /// @notice Requested partial bond refund and payment result.
    /// @param recipient The recipient
    /// @param value The computed refund, whether or not payment succeeded
    /// @param success Whether the requested payment succeeded or was zero
    /// @dev `value` is the computed request, not necessarily the amount
    /// transferred. Recipient execution is gas-bounded and return data is not
    /// copied.
    /// Failure may result from recipient code, call depth, or insufficient
    /// forwarded gas; EOAs may also execute delegated code under EIP-7702. A
    /// zero-value refund skips the callback and reports success.
    event PartialBondRefund(
        address indexed recipient, uint256 value, bool indexed success
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

    /// @notice The amount of Wei passed to `joinTournament` is less than
    /// the bond value (which can be consulted through `bondValue`).
    error InsufficientBond();

    /// @notice Terminal recovery cannot occur because there is no winner.
    error NoWinner();

    /// @notice The divergence falls in the first leaf node of the commitment tree
    /// (in the granularity of the given tournament level), and the state prior
    /// to the divergence (provided by the player) is not equal to the agreed-upon
    /// initial machine state (set forth by the tournament instantiator).
    /// @param initialState The agreed-upon initial machine state
    /// @param agreeState The state prior to the divergence provided by the player
    error IncorrectAgreeState(
        Machine.Hash initialState, Machine.Hash agreeState
    );

    /// @notice A player provided a commitment leaf-node proof that produced
    /// a commitment root different from the one provided to `joinTournament`.
    /// @param expected The expected commitment root
    /// @param computed The commitment root computed from the leaf-node proof
    error CommitmentStateMismatch(Tree.Node expected, Tree.Node computed);

    /// @notice A player provided a commitment leaf-node proof whose length
    /// is different from the commitment tree height.
    /// @param treeHeight The agreed-upon commitment tree height
    /// @param siblingsLength The length of the siblings array provided by the player
    error CommitmentProofWrongSize(uint256 treeHeight, uint256 siblingsLength);

    /// @notice The tournament is finished, which restricts most actions.
    error TournamentIsFinished();

    /// @notice The tournament is not finished, so terminal settlement cannot
    /// occur because a winner has not been declared yet.
    error TournamentNotFinished();

    /// @notice The tournament is closed, which restricts new commitments
    /// from joining the tournament, since the tournament's global allowance
    /// has already elapsed.
    error TournamentIsClosed();

    /// @notice A nested state-changing call tried to re-enter this tournament.
    /// @dev Each tournament clone has an independent transient lock; this error
    /// does not prevent calls to another tournament instance.
    error ReentrancyDetected();

    /// @notice A player provided commitment root children nodes that produced
    /// a commitment root different from the one provided to `joinTournament`.
    /// This error is raised in the context of a match in which one of the
    /// commitments has timed out, and the other hasn't, allowing it to be
    /// paired against any dangling commitment (instantly) or challenging
    /// commitment (that might join the tournament later, if still open).
    /// @param whichCommitment Which of the two commitments did not timeout (1 or 2)
    /// @param commitmentRoot The root of the commitment that did not timeout
    /// @param left The commitment root left child provided by the player
    /// @param right The commitment root right child provided by the player
    error WrongChildren(
        uint256 whichCommitment,
        Tree.Node commitmentRoot,
        Tree.Node left,
        Tree.Node right
    );

    /// @notice A player tried to win a match whose timeout outcome has no
    /// individual winner.
    error MatchCannotBeWonByTimeout();

    /// @notice A player tried to eliminate a match whose timeout outcome is
    /// not double elimination.
    error MatchCannotBeEliminatedByTimeout();

    /// @notice A player tried to join the inner tournament with a commitment
    /// whose final state is not equal to neither of the two contested final states
    /// of the match in the parent tournament that created such inner tournament.
    /// @param contestedFinalStateOne The contested final state #1
    /// @param contestedFinalStateTwo The contested final state #2
    /// @param finalState The final state of the commitment provided by the player
    error InvalidContestedFinalState(
        Machine.Hash contestedFinalStateOne,
        Machine.Hash contestedFinalStateTwo,
        Machine.Hash finalState
    );

    /// @notice The tournament has finished but with no winners.
    /// This is unexpected to happen because we assume that at least
    /// one player is actively defending the correct commitment.
    error TournamentFailedNoWinner();

    /// @notice The child tournament has not yet finished,
    /// and therefore not yet declared a winner.
    error ChildTournamentNotFinished();

    /// @notice The child tournament cannot be eliminated,
    /// either because it has not yet finished or
    /// because the winner still has time to claim its victory.
    error ChildTournamentCannotBeEliminated();

    /// @notice The child tournament cannot be won,
    /// because it can be eliminated.
    error ChildTournamentMustBeEliminated();

    /// @notice The player has provided commitment root children
    /// whose parent is different from the commitment root that won
    /// a child tournament.
    /// @param commitmentRoot The commitment root provided by the player
    /// @param winner The child-tournament winning commitment root
    error WrongTournamentWinner(Tree.Node commitmentRoot, Tree.Node winner);

    /// @notice The on-chain implementation of the state-transition
    /// function applied over an agreed-upon state has produced a
    /// post-state that differs from that of the match commitment.
    /// @param whichCommitment Which of the two commitments is wrong
    /// @param computedPostState The post-state computed by the state-transition function
    /// @param committedPostState The post-state contained within the commitment
    error WrongFinalState(
        uint256 whichCommitment,
        Machine.Hash computedPostState,
        Machine.Hash committedPostState
    );

    /// @notice While trying to win a match through the on-chain implementation
    /// of the state-transition (step) function, a player has supplied the left
    /// and right children of a commitment root that is different from
    /// both commitment roots of a match.
    error WrongNodesForStep();

    /// @notice A player has attempted to call a function that can only be
    /// called for leaf tournaments (in which `level == levels - 1`).
    error RequireLeafTournament();

    /// @notice A player has attempted to call a function that can only be
    /// called for non-leaf tournaments (in which `0 <= level < levels - 1`).
    error RequireNonLeafTournament();

    /// @notice A player has attempted to call a function that can only be
    /// called for non-root tournaments (in which `0 < level <= levels - 1`).
    error RequireNonRootTournament();

    /// @notice A clock wasn't expected to be initialized, but is.
    error ClockAlreadyInitialized();

    /// @notice A clock-dependent progress action cannot continue because a
    /// required clock cannot be preserved under the current timeout accounting.
    /// @dev This includes responding at or after a running clock's deadline and
    /// proving a leaf after the shared classifier selects a timeout outcome.
    error CannotAdvanceTimedOutClock();

    /// @notice The match does not exist.
    /// @dev This happens when the stored match state is not initialized.
    error MatchDoesNotExist();

    /// @notice The match is not sealed.
    /// @dev This happens when the current match height is
    /// either 1 (ready to be sealed) or greater (ready to be advanced).
    error MatchIsNotSealed();

    /// @notice The match cannot be sealed.
    /// @dev This happens when the current match height is
    /// either 0 (sealed) or greater than 1 (ready to be advanced).
    error MatchCannotBeSealed();

    /// @notice The match cannot be advanced.
    /// @dev This happens when the current match height is
    /// either 0 (sealed) or 1 (ready to be sealed).
    error MatchCannotBeAdvanced();

    /// @notice The parent of the provided children nodes
    /// is different from the expected parent node.
    /// @param expectedParent The expected parent node
    /// @param leftChild The left child node
    /// @param rightChild The right child node
    error InvalidChildrenNodes(
        Tree.Node expectedParent, Tree.Node leftChild, Tree.Node rightChild
    );

    //
    // Functions
    //

    /// @notice Get the amount of Wei necessary to call `joinTournament`.
    /// @return The tournament bond value
    /// @dev The bond value may depend on the tournament level.
    function bondValue() external view returns (uint256);

    /// @notice Settle the tournament balance after a winner is established.
    /// @dev Attempts to pay the winning commitment's submitter at most one bond.
    /// The configured refund accounting reserves one complete bond before
    /// terminal recovery. A zero balance defensively completes without calling
    /// the recipient. After a successful payment, any residual balance is
    /// burned and later calls succeed as no-ops. A failed recipient call
    /// preserves the claimer and full balance so recovery can be retried.
    /// @return Whether settlement completed or had already completed
    function tryRecoveringBond() external returns (bool);

    /// @notice Get the tournament's dangling winner and final state.
    /// @dev Intended for root consumers. The current implementation does not
    /// enforce a root-only guard; parents use `innerTournamentWinner` instead.
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
    /// @param finalState The last leaf of the commitment tree (final machine state hash)
    /// @param proof The bottom-up Merkle proof of the last leaf (final machine state hash) of the commitment tree
    /// @param leftNode The commitment root left node
    /// @param rightNode The commitment root right node
    /// @dev Root tournaments are open to everyone,
    /// while non-root tournaments are open to anyone
    /// whose final state hash matches the one of the two in the parent tournament.
    /// This function must be called while passing a
    /// minimum amount of Wei, given by the `bondValue` view function.
    /// The contract will retain any extra amount.
    /// To better illustrate the parameters of this function,
    /// the diagram below displays an example commitment tree
    /// with a purposefully low depth for didatic reasons.
    /// ```
    ///                ROOT
    ///              /      \
    ///           H0123     H4567
    ///          /   \       /   \
    ///       H01   H23   H45    H67
    ///      / \    / \   / \    / \
    ///     0   1  2   3 4   5  6   7
    /// ```
    /// In this diagram, `finalState` is the leaf `7`,
    /// `proof` is the array `[6, H45, H0123]`,
    /// `leftNode` is the node `H0123`,
    /// and `rightNode` is the node `H4567`.
    function joinTournament(
        Machine.Hash finalState,
        bytes32[] calldata proof,
        Tree.Node leftNode,
        Tree.Node rightNode
    ) external payable;

    /// @notice Advance the shared first-divergence frontier by one tree level.
    ///
    /// @dev
    /// ROLE & INPUTS FOR THIS STEP
    /// - `Match.State.otherParent` is the current revealer's parent at height `h`.
    /// - `leftNode` and `rightNode` MUST be its children at height `h - 1`.
    /// - The match compares the supplied revealing left child with the stored
    ///   waiting left child. A mismatch selects left; equality selects right.
    /// - `newLeftNode` and `newRightNode` MUST open the selected revealing child.
    ///   They seed the next turn after the commitment roles flip.
    ///
    /// INVARIANTS (enforced by the library)
    /// - The shared two-tree frontier descends exactly one level per call.
    /// - One commitment supplies two adjacent openings; roles then alternate.
    /// - Every supplied parent-to-child relationship is checked.
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

    /// @notice Resolve a timeout when exactly one commitment can still survive.
    /// @dev During active bisection, the winner is paused and pays the expired
    /// responder's overdue duration. During a sealed leaf, the winner is already
    /// running, so its live remainder accounts for elapsed time and the deferred
    /// charge is zero. The resulting paused clock must remain positive;
    /// otherwise use `eliminateMatchByTimeout`.
    /// @param matchId The logical pair of commitments for this match.
    /// @param leftNode Left child of the winning commitment.
    /// @param rightNode Right child of the winning commitment.
    function winMatchByTimeout(
        Match.Id calldata matchId,
        Tree.Node leftNode,
        Tree.Node rightNode
    ) external;

    /// @notice Permissionless cleanup when neither commitment can survive
    /// timeout accounting.
    /// @dev
    /// During active bisection, elimination applies when the responder is expired
    /// and its overdue duration is at least the paused opponent's remainder;
    /// equality eliminates both. During a sealed leaf, it applies only when both
    /// live remainders are zero. With unequal leaf allowances, the longer clock
    /// wins from the shorter deadline through the block before its own deadline.
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

    /// @notice Propagate an inner tournament winner into its parent match.
    /// @dev The returned clock replaces the selected parent side. Because the
    /// child used the sealed pair's shared maximum, it may exceed that side's
    /// snapshotted remainder but cannot exceed the pair maximum. Child balance
    /// recovery is a separate permissionless operation.
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
    ///   Both participants spend their own remaining allowance during this race.
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

    /// @notice Win a leaf match through the state-transition proof.
    /// @dev Available only while timeout classification is `NONE`. Once either
    /// clock reaches its deadline, this function reverts with
    /// `CannotAdvanceTimedOutClock`; callers must use the timeout verb selected by
    /// the shared classifier. A successful proof snapshots the proven side's
    /// live remainder without a response discount.
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

    /// @notice Check whether an existing match has one timeout winner.
    /// @dev Returns false for a nonexistent match, when neither clock is
    /// expired, and when the outcome is double elimination. This does not
    /// validate the Merkle children required to settle the winning commitment.
    /// @param matchId The match ID
    function canWinMatchByTimeout(Match.Id calldata matchId)
        external
        view
        returns (bool);

    /// @notice Get the clock and final state of a commitment.
    /// @param commitmentRoot The commitment
    /// @return clock The commitment clock
    /// @return finalState The committed final state
    function getCommitment(Tree.Node commitmentRoot)
        external
        view
        returns (Clock.State memory clock, Machine.Hash finalState);

    /// @notice Get a match state by its ID hash.
    /// @dev Returns the raw state tuple without an existence check.
    /// `isInit == false` means absent or deleted. For a valid positive-height
    /// initialized state, the node fields describe the unresolved bisection
    /// segment while `currentHeight > 0`. At `currentHeight == 0`, `otherParent`
    /// holds the agree state while `leftNode` and `rightNode` hold the final
    /// states of commitments one and two respectively.
    /// @param matchIdHash The match ID hash
    function getMatch(Match.IdHash matchIdHash)
        external
        view
        returns (Match.State memory);

    /// @notice Get the running machine cycle of a match by its ID hash.
    /// @dev Before sealing, returns the first cycle in the unresolved segment;
    /// after sealing, returns the disputed transition cycle. Reverts if the
    /// match does not exist or has already been deleted.
    /// @param matchIdHash The match ID hash
    function getMatchCycle(Match.IdHash matchIdHash)
        external
        view
        returns (uint256);

    /// @notice Get tournament-level constants.
    /// @return maxLevel The total level count, despite the legacy return name
    /// @return level The current tournament level
    /// @return log2step The log2 number of steps between commitment leaves
    /// @return height The height of the commitment tree
    function tournamentLevelConstants()
        external
        view
        returns (uint64 maxLevel, uint64 level, uint64 log2step, uint64 height);

    /// @notice Get the number of `CommitmentJoined` events
    /// that have been emitted since the contract was deployed.
    function getCommitmentJoinedCount() external view returns (uint256);

    /// @notice Get the number of `MatchCreated` events
    /// that have been emitted since the contract was deployed.
    function getMatchCreatedCount() external view returns (uint256);

    /// @notice Get the number of `MatchAdvanced` events
    /// that have been emitted since the contract was deployed.
    function getMatchAdvancedCount() external view returns (uint256);

    /// @notice Get the number of `MatchDeleted` events
    /// that have been emitted since the contract was deployed.
    function getMatchDeletedCount() external view returns (uint256);

    /// @notice Get the number of `NewInnerTournament` events
    /// that have been emitted since the contract was deployed.
    function getNewInnerTournamentCount() external view returns (uint256);

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
