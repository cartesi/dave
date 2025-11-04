// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Math} from "@openzeppelin-contracts-5.5.0/utils/math/Math.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Gas} from "prt-contracts/tournament/libs/Gas.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

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
abstract contract Tournament is ITournament {
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

    //
    // Modifiers
    //

    modifier tournamentNotFinished() {
        _ensureTournamentIsNotFinished();
        _;
    }

    modifier tournamentOpen() {
        _ensureTournamentIsOpen();
        _;
    }

    /// @notice Refunds the message sender with the amount
    /// of Ether wasted on gas on this function call plus
    /// a profit, capped by the current contract balance
    /// and a fraction of the bond value.
    /// @param gasEstimate A worst-case gas estimate for the modified function
    /// forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier refundable(uint256 gasEstimate) {
        uint256 gasBefore = _refundableBefore();
        _;
        _refundableAfter(gasBefore, gasEstimate);
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

            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.ONE
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

            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.TWO
            );
        } else {
            revert ClockNotTimedOut();
        }
    }

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
            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.NONE
            );
        } else {
            revert BothClocksHaveNotTimedOut();
        }
    }

    function tryRecoveringBond() public returns (bool) {
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
            deleteClaimer(winningCommitment);
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
    function isClosed() public view returns (bool) {
        TournamentArguments memory args = tournamentArguments();
        return args.startInstant.timeoutElapsed(args.allowance);
    }

    function isFinished() public view returns (bool) {
        return isClosed() && matchCount == 0;
    }

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

    function arbitrationResult()
        external
        view
        override
        returns (bool, Tree.Node, Machine.Hash)
    {
        if (!isFinished()) {
            return (false, Tree.ZERO_NODE, Machine.ZERO_STATE);
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();
        require(_hasDanglingCommitment, TournamentFailedNoWinner());

        Machine.Hash _finalState = finalStates[_danglingCommitment];
        return (true, _danglingCommitment, _finalState);
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
        Match.Id memory _matchId,
        MatchDeletionReason _reason,
        WinnerCommitment _winnerCommitment
    ) internal {
        matchCount--;
        lastMatchDeleted = Time.currentTime();
        if (_winnerCommitment == WinnerCommitment.NONE) {
            deleteClaimer(_matchId.commitmentOne);
            deleteClaimer(_matchId.commitmentTwo);
        } else if (_winnerCommitment == WinnerCommitment.ONE) {
            deleteClaimer(_matchId.commitmentTwo);
        } else if (_winnerCommitment == WinnerCommitment.TWO) {
            deleteClaimer(_matchId.commitmentOne);
        } else {
            revert InvalidWinnerCommitment(_winnerCommitment);
        }
        Match.IdHash _matchIdHash = _matchId.hashFromId();
        delete matches[_matchIdHash];
        emit MatchDeleted(
            _matchIdHash,
            _matchId.commitmentOne,
            _matchId.commitmentTwo,
            _reason,
            _winnerCommitment
        );
    }

    function deleteClaimer(Tree.Node commitment) internal {
        delete claimers[commitment];
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

    /// @notice This function is run at the start of every refundable function.
    /// @return gasBefore The available gas amount before running the function
    /// @dev Ensures the lock is not taken, and takes the lock.
    function _refundableBefore() private returns (uint256 gasBefore) {
        require(!locked, ReentrancyDetected());
        locked = true;
        gasBefore = gasleft();
    }

    /// @notice This function is run at the end of every refundable function.
    /// @param gasBefore The available gas amount before running the function
    /// @param gasEstimate A worst-case gas estimate for the modified function
    /// @dev Releases the lock and tries to refund the sender for the wasted gas.
    /// @dev Emits a BondRefunded event even if the refund fails.
    /// @dev The refund is capped by the contract balance and weighted fraction
    /// of the bond value (where the weight is the expected gas of the function call).
    function _refundableAfter(uint256 gasBefore, uint256 gasEstimate) private {
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

    /// @notice Ensure the tournament is not finished.
    /// @dev Raises a `TournamentNotFinished` error otherwise.
    function _ensureTournamentIsNotFinished() private view {
        require(!isFinished(), TournamentIsFinished());
    }

    /// @notice Ensure the tournament is open (not closed).
    /// @dev Raises a `TournamentIsClosed` error otherwise.
    function _ensureTournamentIsOpen() private view {
        require(!isClosed(), TournamentIsClosed());
    }
}
