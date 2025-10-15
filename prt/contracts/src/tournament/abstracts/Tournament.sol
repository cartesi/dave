// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/ArbitrationConstants.sol";
import "prt-contracts/IDataProvider.sol";
import "prt-contracts/types/TournamentParameters.sol";
import "prt-contracts/types/Machine.sol";
import "prt-contracts/types/Tree.sol";

import "prt-contracts/tournament/libs/Commitment.sol";
import "prt-contracts/tournament/libs/Time.sol";
import "prt-contracts/tournament/libs/Clock.sol";
import "prt-contracts/tournament/libs/Match.sol";
import "prt-contracts/tournament/libs/Gas.sol";

import {Math} from "@openzeppelin-contracts-5.2.0/utils/math/Math.sol";

/// @title Tournament (Abstract) — Asynchronous PRT-style dispute resolution
/// @notice Core, permissionless tournament skeleton that resolves disputes among
/// N parties in O(log N) depth under chess-clock timing. Pairing is asynchronous:
/// claims are matched as they arrive (or when winners re-enter), without a
/// prebuilt bracket.
///
/// @dev
/// MODEL
/// - Structure: Tournaments and matches alternate recursively. Subclasses choose
///   how divergence is resolved (step or nested tournament).
/// - Pairing: Maintains at most one “dangling” (unmatched) commitment. When a
///   second commitment appears (new joiner or last match’s winner), a match is
///   created immediately and the dangling pointer is cleared. If none exists,
///   the newcomer becomes the dangling commitment.
/// - Clocks: Exactly one side’s clock ticks inside any active match; dangling
///   claims are paused. On match creation both sides receive bounded effort
///   allowance (e.g., `matchEffort`, capped by `maxAllowance`). "Late joiners"
///   inherit less remaining allowance (join-time deduction).
/// - Multi-level Tournaments: For computationally viable computation hash,
///   multi-level tournaments allows sparse commitments, but liveness grows to
///   O((log N)^L), where L is the number of levels.
///
/// LIVENESS & COMPLEXITY
/// - At least half the clocks tick at any time, ensuring progress even if arrival
///   order is adversarial. Winners re-enter pairing immediately, preserving
///   logarithmic tournament depth without requiring a balanced bracket.
abstract contract Tournament {
    using Machine for Machine.Hash;
    using Tree for Tree.Node;
    using Commitment for Tree.Node;
    using Commitment for Commitment.Arguments;

    using Time for Time.Instant;
    using Time for Time.Duration;

    using Clock for Clock.State;

    using Match for Match.Id;
    using Match for Match.IdHash;
    using Match for Match.State;

    using Math for uint256;

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

    //
    // Storage
    //
    Tree.Node danglingCommitment;
    uint256 matchCount;
    Time.Instant lastMatchDeleted;

    uint256 constant MAX_GAS_PRICE = 50 gwei;
    uint256 constant MESSAGE_SENDER_PROFIT = 10 gwei;
    bool transient locked;

    mapping(Tree.Node => Clock.State) clocks;
    mapping(Tree.Node => Machine.Hash) finalStates;
    mapping(Tree.Node => address) claimers;

    // matches existing in current tournament
    mapping(Match.IdHash => Match.State) matches;

    enum MatchDeletedReason {
        TIMEOUT_ONE,
        TIMEOUT_TWO,
        BOTH_ELIMINATED,
        SUBGAME_WINNER
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
        MatchDeletedReason reason,
        Tree.Node indexed winnerCommitment
    );
    event CommitmentJoined(
        Tree.Node commitment,
        Machine.Hash finalStateHash,
        address indexed caller
    );

    event BondRefunded(
        address indexed recipient, uint256 value, bool indexed status, bytes ret
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

    //
    // Modifiers
    //
    modifier tournamentNotFinished() {
        require(!isFinished(), TournamentIsFinished());

        _;
    }

    modifier tournamentOpen() {
        require(!isClosed(), TournamentIsClosed());

        _;
    }

    /// @notice Refunds the message sender with the amount
    /// of Ether wasted on gas on this function call plus
    /// a profit, capped by the current contract balance
    /// and a fraction of the bond value.
    /// @param gasEstimate A worst-case gas estimate for the modified function
    modifier refundable(uint256 gasEstimate) {
        require(!locked, ReentrancyDetected());
        locked = true;

        uint256 gasBefore = gasleft();
        _;
        uint256 gasAfter = gasleft();

        uint256 refundValue = _min(
            address(this).balance,
            bondValue() * gasEstimate / _totalGasEstimate(),
            (Gas.TX + gasBefore - gasAfter)
                * (tx.gasprice + MESSAGE_SENDER_PROFIT)
        );

        (bool status, bytes memory ret) =
            msg.sender.call{value: refundValue}("");
        emit BondRefunded(msg.sender, refundValue, status, ret);

        locked = false;
    }

    //
    // Virtual Methods
    //

    /// @return bool if commitment with _finalState is allowed to join the tournament
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        virtual
        returns (bool, Machine.Hash, Machine.Hash);

    function _totalGasEstimate() internal view virtual returns (uint256);

    //
    // Methods
    //
    function bondValue() public view returns (uint256) {
        return _totalGasEstimate() * MAX_GAS_PRICE;
    }

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
    ) external payable tournamentOpen {
        require(msg.value >= bondValue(), InsufficientBond());

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);

        TournamentArguments memory args = tournamentArguments();

        // Prove final state is in commitmentRoot
        _commitmentRoot.requireFinalState(
            args.commitmentArgs.height, _finalState, _proof
        );

        // Verify whether finalState is one of the two allowed of tournament if nested
        requireValidContestedFinalState(_finalState);
        finalStates[_commitmentRoot] = _finalState;

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireNotInitialized(); // reverts if commitment is duplicate
        _clock.setNewPaused(args.startInstant, args.allowance);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);
        claimers[_commitmentRoot] = msg.sender;
        emit CommitmentJoined(_commitmentRoot, _finalState, msg.sender);
    }

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
    ) external refundable(Gas.ADVANCE_MATCH) tournamentNotFinished {
        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireCanBeAdvanced();

        _matchState.advanceMatch(
            _matchId, _leftNode, _rightNode, _newLeftNode, _newRightNode
        );

        // advance clocks
        clocks[_matchId.commitmentOne].advanceClock();
        clocks[_matchId.commitmentTwo].advanceClock();
    }

    function winMatchByTimeout(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external refundable(Gas.WIN_MATCH_BY_TIMEOUT) tournamentNotFinished {
        matches[_matchId.hashFromId()].requireExist();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        if (_clockOne.hasTimeLeft() && !_clockTwo.hasTimeLeft()) {
            require(
                _matchId.commitmentOne.verify(_leftNode, _rightNode),
                WrongChildren(1, _matchId.commitmentOne, _leftNode, _rightNode)
            );

            _clockOne.deducted(_clockTwo.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentOne, _clockOne, _leftNode, _rightNode
            );

            // clear the claimer for the losing commitment
            delete claimers[_matchId.commitmentTwo];
            // delete storage
            deleteMatch(
                _matchId.hashFromId(),
                MatchDeletedReason.TIMEOUT_TWO,
                _matchId.commitmentOne
            );
        } else if (!_clockOne.hasTimeLeft() && _clockTwo.hasTimeLeft()) {
            require(
                _matchId.commitmentTwo.verify(_leftNode, _rightNode),
                WrongChildren(2, _matchId.commitmentTwo, _leftNode, _rightNode)
            );

            _clockTwo.deducted(_clockOne.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentTwo, _clockTwo, _leftNode, _rightNode
            );

            // clear the claimer for the losing commitment
            delete claimers[_matchId.commitmentOne];
            // delete storage
            deleteMatch(
                _matchId.hashFromId(),
                MatchDeletedReason.TIMEOUT_ONE,
                _matchId.commitmentTwo
            );
        } else {
            revert ClockNotTimedOut();
        }
    }

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
    function eliminateMatchByTimeout(Match.Id calldata _matchId)
        external
        refundable(Gas.ELIMINATE_MATCH_BY_TIMEOUT)
        tournamentNotFinished
    {
        matches[_matchId.hashFromId()].requireExist();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        // check if both clocks are out of time
        if (
            (!_clockOne.hasTimeLeft()
                    && !_clockTwo.timeLeft().gt(_clockOne.timeSinceTimeout()))
                || (!_clockTwo.hasTimeLeft()
                    && !_clockOne.timeLeft().gt(_clockTwo.timeSinceTimeout()))
        ) {
            // delete storage

            // clear the claimer for both commitments
            delete claimers[_matchId.commitmentOne];
            delete claimers[_matchId.commitmentTwo];
            deleteMatch(
                _matchId.hashFromId(),
                MatchDeletedReason.BOTH_ELIMINATED,
                Tree.ZERO_NODE
            );
        } else {
            revert BothClocksHaveNotTimedOut();
        }
    }

    function tryRecoveringBond() public virtual returns (bool) {
        require(isFinished(), TournamentNotFinished());

        // Ensure there is a winner
        (bool hasDangling, Tree.Node winningCommitment) =
            hasDanglingCommitment();
        require(hasDangling, NoWinner());

        // Get the address associated with the winning claim
        address winner = claimers[winningCommitment];
        assert(winner != address(0));

        // Refund the entire contract balance to the winner
        uint256 contractBalance = address(this).balance;
        (bool success,) = winner.call{value: contractBalance}("");

        // clear the claimer for the winning commitment if successfully recovered bond
        if (success) {
            delete claimers[winningCommitment];
        }

        return success;
    }

    //
    // View methods
    //
    function tournamentArguments()
        public
        view
        virtual
        returns (TournamentArguments memory);

    function canWinMatchByTimeout(Match.Id calldata _matchId)
        external
        view
        returns (bool)
    {
        Clock.State memory _clockOne = clocks[_matchId.commitmentOne];
        Clock.State memory _clockTwo = clocks[_matchId.commitmentTwo];

        return !_clockOne.hasTimeLeft() || !_clockTwo.hasTimeLeft();
    }

    function getCommitment(Tree.Node _commitmentRoot)
        public
        view
        returns (Clock.State memory, Machine.Hash)
    {
        return (clocks[_commitmentRoot], finalStates[_commitmentRoot]);
    }

    function getMatch(Match.IdHash _matchIdHash)
        public
        view
        returns (Match.State memory)
    {
        return matches[_matchIdHash];
    }

    function getMatchCycle(Match.IdHash _matchIdHash)
        external
        view
        returns (uint256)
    {
        Match.State memory _m = getMatch(_matchIdHash);
        Commitment.Arguments memory args = tournamentArguments().commitmentArgs;

        return args.toCycle(_m.runningLeafPosition);
    }

    function tournamentLevelConstants()
        external
        view
        returns (
            uint64 _maxLevel,
            uint64 _level,
            uint64 _log2step,
            uint64 _height
        )
    {
        TournamentArguments memory args;
        args = tournamentArguments();
        _maxLevel = args.levels;
        _level = args.level;
        _log2step = args.commitmentArgs.log2step;
        _height = args.commitmentArgs.height;
    }

    //
    // Time view methods
    //

    /// @return bool if the tournament is still open to join
    function isClosed() public view returns (bool) {
        TournamentArguments memory args = tournamentArguments();
        return args.startInstant.timeoutElapsed(args.allowance);
    }

    /// @return bool if the tournament is over
    function isFinished() public view returns (bool) {
        return isClosed() && matchCount == 0;
    }

    /// @notice returns if and when tournament was finished.
    /// @return (bool, Time.Instant)
    /// - if the tournament can be eliminated
    /// - the time when the tournament was finished
    function timeFinished() public view returns (bool, Time.Instant) {
        if (!isFinished()) {
            return (false, Time.ZERO_INSTANT);
        }

        TournamentArguments memory args = tournamentArguments();

        // Here, we know that `lastMatchDeleted` holds the Instant when `matchCount` became zero.
        // However, we still must consider when the tournament was closed, in case it
        // happens after `lastMatchDeleted`.
        // Note that `lastMatchDeleted` could be zero if there are no matches eliminated.
        // In this case, we'd only care about `tournamentClosed`.
        Time.Instant tournamentClosed = args.startInstant.add(args.allowance);
        Time.Instant winnerCouldWin = tournamentClosed.max(lastMatchDeleted);

        return (true, winnerCouldWin);
    }

    //
    // Internal functions
    //
    function setDanglingCommitment(Tree.Node _node) internal {
        danglingCommitment = _node;
    }

    function clearDanglingCommitment() internal {
        danglingCommitment = Tree.ZERO_NODE;
    }

    function hasDanglingCommitment()
        internal
        view
        returns (bool _h, Tree.Node _node)
    {
        _node = danglingCommitment;

        if (!_node.isZero()) {
            _h = true;
        }
    }

    /// @dev Pair a new commitment into the tournament, creating a match if an
    ///      unmatched opponent is waiting, or queuing this commitment otherwise.
    ///      Guarantees continuous progress by (a) keeping at most one dangling
    ///      commitment and (b) enforcing chess-clock style timing on matches.
    /// @param _rootHash   The commitment (Merkle root) for the new/advancing claim.
    /// @param _newClock   Storage reference to the clock state tied to `_rootHash`.
    /// @param _leftNode   Left child; must join with right to form `_rootHash`.
    /// @param _rightNode  Right child; must join with left to form `_rootHash`.
    ///
    /// Invariants / Effects:
    /// - Verifies `_leftNode.join(_rightNode) == _rootHash`.
    /// - If a dangling opponent exists:
    ///     * Creates a Match between dangling and `_rootHash`.
    ///     * Credits bounded match effort to both clocks (anti-starvation).
    ///     * Toggles the previously dangling clock to start its turn.
    ///     * Clears the dangling pointer; increments match counter; emits `matchCreated`.
    /// - Otherwise: stores `_rootHash` as the dangling commitment and pauses its clock.
    ///
    /// Rationale:
    /// - Asynchronous matchmaking avoids fixed brackets and preserves O(log N) progress
    ///   under Dave-style chess clocks by ensuring at least half the clocks tick at all times.
    /// - Late arrivals are deducted their delay and as such do not gain extra time.
    function pairCommitment(
        Tree.Node _rootHash,
        Clock.State storage _newClock,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) internal {
        assert(_leftNode.join(_rightNode).eq(_rootHash));
        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();

        if (_hasDanglingCommitment) {
            TournamentArguments memory args = tournamentArguments();
            (Match.IdHash _matchId, Match.State memory _matchState) = Match.createMatch(
                args.commitmentArgs,
                _danglingCommitment,
                _rootHash,
                _leftNode,
                _rightNode
            );

            matches[_matchId] = _matchState;

            Clock.State storage _firstClock = clocks[_danglingCommitment];

            // grant extra match effort for both clocks
            _firstClock.addMatchEffort(args.matchEffort, args.maxAllowance);
            _newClock.addMatchEffort(args.matchEffort, args.maxAllowance);

            // toggle clock of first claim
            _firstClock.advanceClock();

            clearDanglingCommitment();
            matchCount++;

            emit MatchCreated(
                _matchId, _danglingCommitment, _rootHash, _leftNode
            );
        } else {
            setDanglingCommitment(_rootHash);
        }
    }

    function deleteMatch(
        Match.IdHash _matchIdHash,
        MatchDeletedReason _reason,
        Tree.Node _winnerCommitment
    ) internal {
        matchCount--;
        lastMatchDeleted = Time.currentTime();
        delete matches[_matchIdHash];
        emit MatchDeleted(_matchIdHash, _reason, _winnerCommitment);
    }

    function requireValidContestedFinalState(Machine.Hash _finalState)
        internal
        view
    {
        (
            bool valid,
            Machine.Hash contestedFinalStateOne,
            Machine.Hash contestedFinalStateTwo
        ) = validContestedFinalState(_finalState);
        require(
            valid,
            InvalidContestedFinalState(
                contestedFinalStateOne, contestedFinalStateTwo, _finalState
            )
        );
    }

    /// @notice Returns the minimum of three values
    /// @param a First value
    /// @param b Second value
    /// @param c Third value
    /// @return The minimum value
    function _min(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256)
    {
        return a.min(b).min(c);
    }
}
