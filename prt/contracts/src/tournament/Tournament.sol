// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";
import {Math} from "@openzeppelin-contracts-5.5.0/utils/math/Math.sol";

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";
import {Bond} from "prt-contracts/tournament/libs/Bond.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Gas} from "prt-contracts/tournament/libs/Gas.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {MatchClocks} from "prt-contracts/tournament/libs/MatchClocks.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @title Tournament - Asynchronous PRT-style dispute resolution
/// @notice Core, permissionless tournament that resolves disputes among
/// N parties under chess-clock timing. Each match compares two commitment trees
/// by alternating which tree is bisected. Total adversarial delay also depends
/// on repeated pairing and tournament levels. Pairing is asynchronous: claims
/// are matched as they arrive (or when winners re-enter), without a prebuilt
/// bracket.
///
/// @dev
/// HIGH-LEVEL ROLE SPLIT (BY LEVEL)
/// - Root tournaments (level == 0, arbitrary levels >= 1):
///   * Entry point via `joinTournament`.
///   * Never have a parent match or contested final states.
///   * Cannot be eliminated (`canBeEliminated` reverts with `RequireNonRootTournament`).
///   * Winner is obtained via `arbitrationResult`.
///
/// - Inner, non-root tournaments (level > 0, arbitrary levels >= 2):
///   * A parent-linked instance is created by
///     `sealInnerMatchAndCreateInnerTournament`; permissionless factory callers
///     may also create orphan instances that no parent recognizes.
///   * Have exactly two contested final states, stored in `NestedDispute`.
///   * Can be eliminated by the parent once the inner winner's allowance
///     window expires.
///   * Winner is obtained via `innerTournamentWinner`.
///
/// - Leaf vs. non-leaf tournaments (by `level` vs `levels`):
///   * Leaf tournaments (level == levels - 1):
///       - Use `sealLeafMatch` and `winLeafMatch` (on-chain state transition).
///       - Do NOT create further inner tournaments.
///   * Non-leaf tournaments (level < levels - 1):
///       - Use `sealInnerMatchAndCreateInnerTournament` and `winInnerTournament`.
///       - Can recursively create new inner tournaments via `instantiateInner`.
contract Tournament is ITournament {
    using Clones for address;
    using Machine for Machine.Hash;
    using Tree for Tree.Node;
    using Commitment for Tree.Node;
    using Commitment for Commitment.Arguments;

    using Time for Time.Instant;
    using Time for Time.Duration;

    using Clock for Clock.State;

    using Match for Match.Id;
    using Match for Match.State;

    using Math for uint256;

    //
    // Storage
    //
    Tree.Node danglingCommitment;
    uint256 matchCount;
    Time.Instant lastMatchDeleted;
    uint256 commitmentJoinedCount;
    uint256 matchCreatedCount;
    uint256 matchAdvancedCount;
    uint256 matchDeletedCount;
    uint256 newInnerTournamentCount;

    bool transient locked;

    mapping(Tree.Node => Clock.State) clocks;
    mapping(Tree.Node => Machine.Hash) finalStates;
    mapping(Tree.Node => address) claimers;

    // matches existing in current tournament
    mapping(Match.IdHash => Match.State) matches;

    /// @notice Mapping from inner tournament to its originating match id
    /// @dev Used by nested (non-leaf) tournaments
    mapping(ITournament => Match.Id) matchIdFromInnerTournaments;

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

    /// @notice Acquires this tournament clone's lock for the modified call.
    /// @dev Blocks nested state-changing calls to this instance. Other
    /// tournament clones have independent transient locks.
    modifier withLock() {
        _acquireLock();
        _;
        _releaseLock();
    }

    /// @notice Computes and attempts a bounded gross-EVM work subsidy.
    /// @dev The requested value is capped by the current balance, this action's
    /// configured refund cap, and measured work plus a fixed overhead at the
    /// capped price. The event records that request even if the recipient call
    /// fails and transfers nothing. Dynamic calldata, receipt-exact cost,
    /// chain-specific fees, and caller profit are not guaranteed.
    /// Also acquires the lock beforehand and releases it afterward.
    /// @param gasEstimate The configured allocation for the modified function
    /// forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier refundable(uint256 gasEstimate) {
        uint256 gasBefore = _refundableBefore();
        _;
        _refundableAfter(gasBefore, gasEstimate);
    }

    //
    // Internal helpers and virtual-like methods
    //

    /// @notice Get tournament arguments for this tournament instance
    /// @dev Decodes immutable arguments passed during clone creation
    function _tournamentArgs()
        internal
        view
        returns (TournamentArguments memory)
    {
        return abi.decode(address(this).fetchCloneArgs(), (TournamentArguments));
    }

    /// @inheritdoc ITournament
    function tournamentArguments()
        public
        view
        override
        returns (TournamentArguments memory)
    {
        return _tournamentArgs();
    }

    /// @notice Check if this tournament is a leaf tournament (level == levels - 1)
    function _isLeafTournament(TournamentArguments memory _args)
        internal
        pure
        returns (bool)
    {
        return _args.level == _args.levels - 1;
    }

    /// @notice Check if this tournament is a root tournament (level == 0)
    function _isRootTournament(TournamentArguments memory _args)
        internal
        pure
        returns (bool)
    {
        return _args.level == 0;
    }

    /// @notice Check if a final state is allowed to join the tournament.
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        returns (bool, Machine.Hash, Machine.Hash)
    {
        TournamentArguments memory args = tournamentArguments();

        // ROOT CASE: level == 0
        // - Root tournaments are open to all participants, so any final state is valid.
        // - There is no concept of "contested final states" at level 0.
        if (args.level == 0) {
            return (true, Machine.ZERO_STATE, Machine.ZERO_STATE);
        }

        // NON-ROOT CASE: level > 0
        // - Inner tournaments only accept commitments that match one of the two
        //   contested final states from the parent match that created them.
        NestedDispute memory nestedDispute = args.nestedDispute;
        return (
            nestedDispute.contestedFinalStateOne.eq(_finalState)
                || nestedDispute.contestedFinalStateTwo.eq(_finalState),
            nestedDispute.contestedFinalStateOne,
            nestedDispute.contestedFinalStateTwo
        );
    }

    //
    // Methods
    //

    function bondValue() public view override returns (uint256) {
        TournamentArguments memory args = tournamentArguments();
        return
            Bond.bondValue(args.commitmentArgs.height, _isLeafTournament(args));
    }

    /// @notice Join a tournament (root or inner) with a commitment.
    /// @dev
    /// - ROOT (level == 0):
    ///     * Open to all final states, contested fields in TournamentArguments are zero.
    /// - NON-ROOT (level > 0):
    ///     * Final state must match one of the two contested final states.
    /// - Clock initialization deducts time since this tournament's start, so a
    ///   late join never receives the original allowance in full.
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external payable override withLock tournamentOpen {
        require(msg.value >= bondValue(), InsufficientBond());

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);

        TournamentArguments memory args = tournamentArguments();

        _commitmentRoot.requireFinalState(
            args.commitmentArgs.height, _finalState, _proof
        );

        requireValidContestedFinalState(_finalState);
        finalStates[_commitmentRoot] = _finalState;

        Clock.State storage _clock = clocks[_commitmentRoot];
        Time.Instant current = Time.currentTime();
        _clock.initializePausedAt(args.startInstant, args.allowance, current);

        _emitCommitmentJoined(_commitmentRoot, _finalState, msg.sender);
        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode, current);
        claimers[_commitmentRoot] = msg.sender;
    }

    /// @inheritdoc ITournament
    function advanceMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Tree.Node _newLeftNode,
        Tree.Node _newRightNode
    ) external override refundable(Gas.ADVANCE_MATCH) tournamentNotFinished {
        Match.IdHash matchIdHash = _matchId.hashFromId();
        Match.State storage _matchState = matches[matchIdHash];
        _matchState.requireCanBeAdvanced();

        _matchState.advanceBisection(
            _leftNode, _rightNode, _newLeftNode, _newRightNode
        );

        Time.Duration responseBudget = tournamentArguments().responseBudget;
        MatchClocks.switchTurnAt(
            clocks[_matchId.commitmentOne],
            clocks[_matchId.commitmentTwo],
            responseBudget,
            Time.currentTime()
        );

        _emitMatchAdvanced(
            matchIdHash, _matchState.otherParent, _matchState.leftNode
        );
    }

    /// @notice Win a match by timeout at any level (root or inner).
    /// @dev
    /// - Behavior is identical for root and inner tournaments; level only affects
    ///   how the winner is later interpreted by parent tournaments.
    /// - A paused winner is charged the loser's overdue time. A running winner
    ///   has already paid for the same interval through its live remaining time,
    ///   so no additional charge applies.
    /// - The winner must retain positive time after any deferred charge;
    ///   otherwise both commitments must be eliminated through
    ///   `eliminateMatchByTimeout`.
    /// - The call fails when the shared classifier selects no individual winner.
    function winMatchByTimeout(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    )
        external
        override
        refundable(Gas.WIN_MATCH_BY_TIMEOUT)
        tournamentNotFinished
    {
        // The legal clock configuration encodes the match phase, so an
        // existing match needs no separate structural decode here.
        matches[_matchId.hashFromId()].requireExists();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        Time.Instant current = Time.currentTime();
        MatchClocks.TimeoutStatus memory timeout =
            MatchClocks.classifyTimeoutAt(_clockOne, _clockTwo, current);

        if (timeout.outcome == MatchClocks.TimeoutOutcome.ONE_WINS) {
            require(
                _matchId.commitmentOne.verify(_leftNode, _rightNode),
                WrongChildren(1, _matchId.commitmentOne, _leftNode, _rightNode)
            );

            _clockOne.chargeAndPauseAt(timeout.deferredCharge, current);
            pairCommitment(
                _matchId.commitmentOne,
                _clockOne,
                _leftNode,
                _rightNode,
                current
            );

            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.ONE
            );
        } else if (timeout.outcome == MatchClocks.TimeoutOutcome.TWO_WINS) {
            require(
                _matchId.commitmentTwo.verify(_leftNode, _rightNode),
                WrongChildren(2, _matchId.commitmentTwo, _leftNode, _rightNode)
            );

            _clockTwo.chargeAndPauseAt(timeout.deferredCharge, current);
            pairCommitment(
                _matchId.commitmentTwo,
                _clockTwo,
                _leftNode,
                _rightNode,
                current
            );

            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.TWO
            );
        } else {
            revert MatchCannotBeWonByTimeout();
        }
    }

    function eliminateMatchByTimeout(Match.Id calldata _matchId)
        external
        override
        refundable(Gas.ELIMINATE_MATCH_BY_TIMEOUT)
        tournamentNotFinished
    {
        // The legal clock configuration encodes the match phase, so an
        // existing match needs no separate structural decode here.
        matches[_matchId.hashFromId()].requireExists();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        Time.Instant current = Time.currentTime();
        MatchClocks.TimeoutStatus memory timeout =
            MatchClocks.classifyTimeoutAt(_clockOne, _clockTwo, current);

        if (timeout.outcome == MatchClocks.TimeoutOutcome.ELIMINATE_BOTH) {
            deleteMatch(
                _matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.NONE
            );
        } else {
            revert MatchCannotBeEliminatedByTimeout();
        }
    }

    /// @notice Settle the tournament balance after a winner is established.
    /// @dev
    /// - ROOT:
    ///     * Winner is the root tournament winner.
    /// - NON-ROOT:
    ///     * Winner is the inner winner that will be used by the parent tournament.
    /// - Configured refund caps reserve one minimum join bond; the
    ///   defensive payment remains capped by the current balance.
    /// - A zero balance completes without calling the winner.
    /// - Any post-payment residual balance is burned.
    /// - A call after successful recovery returns true without another transfer.
    /// - A failed winner payment preserves the claimer and balance for retry.
    /// - Recipient code runs within the configured payment callback gas limit.
    function tryRecoveringBond() public override withLock returns (bool) {
        require(isFinished(), TournamentNotFinished());

        (bool hasDangling, Tree.Node winningCommitment) =
            hasDanglingCommitment();
        require(hasDangling, NoWinner());

        address winnerClaimer = claimers[winningCommitment];
        if (winnerClaimer == address(0)) {
            // A successful recovery deletes the claimer. Treat later
            // permissionless recovery attempts as successful no-ops.
            return true;
        }

        uint256 winnerPayment = address(this).balance.min(bondValue());
        if (!_tryPayment(winnerClaimer, winnerPayment)) {
            return false;
        }

        uint256 residualBalance = address(this).balance;
        if (residualBalance > 0) {
            (bool success,) =
                payable(address(0)).call{value: residualBalance}("");
            assert(success);
        }

        // The external payment precedes this effect so a rejecting winner can
        // retry. The instance-local transient lock prevents re-entering this
        // tournament during both transfers.
        deleteClaimer(winningCommitment);
        return true;
    }

    //
    // Leaf tournament operations
    //

    /// @inheritdoc ITournament
    /// @dev
    /// - LEAF ONLY (level == levels - 1):
    ///     * Seals a leaf-level match using the on-chain state commitment tree.
    /// - NON-LEAF (level < levels - 1):
    ///     * Not implemented; will revert with `RequireLeafTournament`.
    function sealLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external override refundable(Gas.SEAL_LEAF_MATCH) tournamentNotFinished {
        TournamentArguments memory args = tournamentArguments();
        if (!_isLeafTournament(args)) {
            revert RequireLeafTournament();
        }

        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireCanBeSealed();

        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            MatchClocks.startLeafRaceAt(
                _clock1, _clock2, args.responseBudget, Time.currentTime()
            );
        }

        _matchState.sealDivergence(
            args.commitmentArgs,
            _matchId,
            _leftLeaf,
            _rightLeaf,
            _agreeHash,
            _agreeHashProof
        );
    }

    /// @inheritdoc ITournament
    function winLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        bytes calldata proofs
    ) external override refundable(Gas.WIN_LEAF_MATCH) tournamentNotFinished {
        TournamentArguments memory args = tournamentArguments();
        if (!_isLeafTournament(args)) {
            revert RequireLeafTournament();
        }

        Match.SealedView memory divergence =
            Match.sealedView(matches[_matchId.hashFromId()]);
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];
        _clockOne.assertInitialized();
        _clockTwo.assertInitialized();
        Time.Instant current = Time.currentTime();
        MatchClocks.TimeoutStatus memory timeout =
            MatchClocks.classifyTimeoutAt(_clockOne, _clockTwo, current);
        if (timeout.outcome != MatchClocks.TimeoutOutcome.NONE) {
            revert CannotAdvanceTimedOutClock();
        }

        uint256 agreeCycle =
            args.commitmentArgs.toCycle(divergence.divergencePosition);

        // The entire dispute converges here: verify the one machine transition
        // immediately after the last state on which both commitments agree.
        IStateTransition stateTransition = _tournamentArgs().stateTransition;
        Machine.Hash _finalState = Machine.Hash
            .wrap(
                stateTransition.transitionState(
                    Machine.Hash.unwrap(divergence.agreeState),
                    agreeCycle,
                    proofs,
                    args.provider
                )
            );

        if (_leftNode.join(_rightNode).eq(_matchId.commitmentOne)) {
            require(
                _finalState.eq(divergence.finalStateOne),
                WrongFinalState(1, _finalState, divergence.finalStateOne)
            );

            _clockOne.chargeAndPauseAt(Time.ZERO_DURATION, current);
            pairCommitment(
                _matchId.commitmentOne,
                _clockOne,
                _leftNode,
                _rightNode,
                current
            );

            deleteMatch(
                _matchId, MatchDeletionReason.STEP, WinnerCommitment.ONE
            );
        } else if (_leftNode.join(_rightNode).eq(_matchId.commitmentTwo)) {
            require(
                _finalState.eq(divergence.finalStateTwo),
                WrongFinalState(2, _finalState, divergence.finalStateTwo)
            );

            _clockTwo.chargeAndPauseAt(Time.ZERO_DURATION, current);
            pairCommitment(
                _matchId.commitmentTwo,
                _clockTwo,
                _leftNode,
                _rightNode,
                current
            );

            deleteMatch(
                _matchId, MatchDeletionReason.STEP, WinnerCommitment.TWO
            );
        } else {
            revert WrongNodesForStep();
        }
    }

    //
    // Inner (non-leaf) tournament operations
    //

    /// @inheritdoc ITournament
    /// @dev
    /// - NON-LEAF ONLY (level < levels - 1):
    ///     * Seals an inner match and spawns an inner tournament at `level + 1`.
    /// - LEAF (level == levels - 1):
    ///     * Not implemented; will revert with `RequireNonLeafTournament`.
    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    )
        external
        override
        refundable(Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT)
        tournamentNotFinished
    {
        TournamentArguments memory args = tournamentArguments();
        if (_isLeafTournament(args)) {
            revert RequireNonLeafTournament();
        }

        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireCanBeSealed();

        Time.Duration _maxDuration;
        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _maxDuration = MatchClocks.pauseForInnerAt(
                _clock1, _clock2, args.responseBudget, Time.currentTime()
            );
        }

        (Machine.Hash _finalStateOne, Machine.Hash _finalStateTwo) = _matchState.sealDivergence(
            args.commitmentArgs,
            _matchId,
            _leftLeaf,
            _rightLeaf,
            _agreeHash,
            _agreeHashProof
        );

        ITournament _inner = instantiateInner(
            _agreeHash,
            _matchId.commitmentOne,
            _finalStateOne,
            _matchId.commitmentTwo,
            _finalStateTwo,
            _maxDuration,
            args.commitmentArgs.toCycle(_matchState.runningLeafPosition),
            args.level + 1
        );
        matchIdFromInnerTournaments[_inner] = _matchId;

        _emitNewInnerTournament(_matchId.hashFromId(), _inner);
    }

    /// @inheritdoc ITournament
    function winInnerTournament(
        ITournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    )
        external
        override
        refundable(Gas.WIN_INNER_TOURNAMENT)
        tournamentNotFinished
    {
        TournamentArguments memory args = tournamentArguments();
        if (_isLeafTournament(args)) {
            revert RequireNonLeafTournament();
        }

        Match.Id memory _matchId = matchIdFromInnerTournaments[_childTournament];
        Match.IdHash _matchIdHash = _matchId.hashFromId();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireSealed();

        require(
            !_childTournament.canBeEliminated(),
            ChildTournamentMustBeEliminated()
        );

        (bool finished, Tree.Node _winner,, Clock.State memory _innerClock) =
            _childTournament.innerTournamentWinner();
        require(finished, ChildTournamentNotFinished());

        WinnerCommitment _winnerCommitment;
        if (_winner.eq(_matchId.commitmentOne)) {
            _winnerCommitment = WinnerCommitment.ONE;
        } else {
            assert(_winner.eq(_matchId.commitmentTwo));
            _winnerCommitment = WinnerCommitment.TWO;
        }

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);
        require(
            _commitmentRoot.eq(_winner),
            WrongTournamentWinner(_commitmentRoot, _winner)
        );

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.assertInitialized();
        // A child carries the sealed pair's shared maximum. It may therefore
        // exceed this selected side's snapshot, but never the pair maximum or
        // the sealed pair's post-discount live clock mass.
        _clock.replaceWithPaused(_innerClock);

        pairCommitment(
            _commitmentRoot, _clock, _leftNode, _rightNode, Time.currentTime()
        );

        deleteMatch(
            _matchId, MatchDeletionReason.CHILD_TOURNAMENT, _winnerCommitment
        );
        delete matchIdFromInnerTournaments[_childTournament];
    }

    /// @inheritdoc ITournament
    function eliminateInnerTournament(ITournament _childTournament)
        external
        override
        refundable(Gas.ELIMINATE_INNER_TOURNAMENT)
        tournamentNotFinished
    {
        TournamentArguments memory args = tournamentArguments();
        if (_isLeafTournament(args)) {
            revert RequireNonLeafTournament();
        }

        Match.Id memory _matchId = matchIdFromInnerTournaments[_childTournament];
        Match.IdHash _matchIdHash = _matchId.hashFromId();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireSealed();

        require(
            _childTournament.canBeEliminated(),
            ChildTournamentCannotBeEliminated()
        );

        deleteMatch(
            _matchId,
            MatchDeletionReason.CHILD_TOURNAMENT,
            WinnerCommitment.NONE
        );
        delete matchIdFromInnerTournaments[_childTournament];
    }

    /// @notice Instantiate an inner tournament using the configured factory.
    /// @dev
    /// - Called only on NON-LEAF tournaments.
    /// - The factory determines leaf vs non-leaf configuration based on `_level`.
    function instantiateInner(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) private returns (ITournament) {
        TournamentArguments memory args = tournamentArguments();

        IMultiLevelTournamentFactory tournamentFactory =
            IMultiLevelTournamentFactory(_tournamentArgs().tournamentFactory);
        return tournamentFactory.instantiateInner(
            _initialHash,
            _contestedCommitmentOne,
            _contestedFinalStateOne,
            _contestedCommitmentTwo,
            _contestedFinalStateTwo,
            _allowance,
            _startCycle,
            _level,
            args.provider
        );
    }

    //
    // View methods
    //

    function canWinMatchByTimeout(Match.Id calldata _matchId)
        external
        view
        override
        returns (bool)
    {
        if (!matches[_matchId.hashFromId()].exists()) {
            return false;
        }

        Clock.State memory _clockOne = clocks[_matchId.commitmentOne];
        Clock.State memory _clockTwo = clocks[_matchId.commitmentTwo];
        MatchClocks.TimeoutStatus memory timeout = MatchClocks.classifyTimeoutAt(
            _clockOne, _clockTwo, Time.currentTime()
        );

        return timeout.outcome == MatchClocks.TimeoutOutcome.ONE_WINS
            || timeout.outcome == MatchClocks.TimeoutOutcome.TWO_WINS;
    }

    function getCommitment(Tree.Node _commitmentRoot)
        public
        view
        override
        returns (Clock.State memory, Machine.Hash)
    {
        return (clocks[_commitmentRoot], finalStates[_commitmentRoot]);
    }

    function getMatch(Match.IdHash _matchIdHash)
        public
        view
        override
        returns (Match.State memory)
    {
        return matches[_matchIdHash];
    }

    function getMatchCycle(Match.IdHash _matchIdHash)
        external
        view
        override
        returns (uint256)
    {
        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExists();
        Commitment.Arguments memory args = tournamentArguments().commitmentArgs;

        return args.toCycle(_matchState.runningLeafPosition);
    }

    /// @notice Return core tournament parameters derived from `TournamentArguments`.
    /// @dev
    /// - `maxLevel` (levels): total number of levels in the hierarchy.
    /// - `level`: this tournament's level.
    /// - `log2step` / `height`: leaf spacing and tree height for commitments.
    function tournamentLevelConstants()
        external
        view
        override
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

    /// @notice Returns true iff the tournament's global allowance has elapsed.
    /// @dev
    /// - ROOT and NON-ROOT:
    ///     * Same behavior: closed if `now >= startInstant + allowance`.
    function isClosed() public view override returns (bool) {
        TournamentArguments memory args = tournamentArguments();
        return args.startInstant.timeoutElapsed(args.allowance);
    }

    /// @notice Returns true iff the tournament is closed and has no active matches.
    /// @dev
    /// - ROOT:
    ///     * Finished when there are no more matches and the global timeout elapsed.
    /// - NON-ROOT:
    ///     * Same condition; used both for elimination and inner-winner computation.
    function isFinished() public view override returns (bool) {
        return isClosed() && matchCount == 0;
    }

    /// @notice Returns the time at which this tournament became "safe to decide".
    /// @dev
    /// - ROOT:
    ///     * Observable, but not consumed by root settlement.
    /// - NON-ROOT:
    ///     * Used by `canBeEliminated` and `innerTournamentWinner`.
    function timeFinished() public view override returns (bool, Time.Instant) {
        if (!isFinished()) {
            return (false, Time.ZERO_INSTANT);
        }

        TournamentArguments memory args = tournamentArguments();

        Time.Instant tournamentClosed = args.startInstant.add(args.allowance);
        Time.Instant winnerCouldWin = tournamentClosed.max(lastMatchDeleted);

        return (true, winnerCouldWin);
    }

    /// @notice Get this tournament's dangling winner and final state.
    /// @dev
    /// - Intended for root consumers, but no root-only guard is enforced.
    /// - Parents use `innerTournamentWinner` for non-root tournaments.
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

    /// @notice Pair a new commitment into the tournament, creating a match if an
    /// existing dangling commitment is available.
    /// @dev If there's a dangling commitment, creates a match between it and the
    /// new commitment and starts only the older dangling clock. Pairing changes
    /// neither balance. Otherwise, stores the new commitment as dangling.
    function pairCommitment(
        Tree.Node _rootHash,
        Clock.State storage _newClock,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Time.Instant current
    ) internal {
        assert(_leftNode.join(_rightNode).eq(_rootHash));
        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();

        if (_hasDanglingCommitment) {
            TournamentArguments memory args = tournamentArguments();
            (Match.IdHash _matchId, Match.State memory _matchState) = Match.create(
                args.commitmentArgs.height,
                _danglingCommitment,
                _rootHash,
                _leftNode,
                _rightNode
            );

            matches[_matchId] = _matchState;

            Clock.State storage _firstClock = clocks[_danglingCommitment];
            MatchClocks.startBisectionAt(_firstClock, _newClock, current);

            clearDanglingCommitment();
            matchCount++;

            _emitMatchCreated(
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
        } else {
            assert(_winnerCommitment == WinnerCommitment.TWO);
            deleteClaimer(_matchId.commitmentOne);
        }
        Match.IdHash _matchIdHash = _matchId.hashFromId();
        delete matches[_matchIdHash];
        _emitMatchDeleted(_matchIdHash, _matchId, _reason, _winnerCommitment);
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

    function _min(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256)
    {
        return a.min(b).min(c);
    }

    function _acquireLock() private {
        require(!locked, ReentrancyDetected());
        locked = true;
    }

    function _releaseLock() private {
        locked = false;
    }

    function _refundableBefore() private returns (uint256 gasBefore) {
        _acquireLock();
        gasBefore = gasleft();
    }

    function _refundableAfter(uint256 gasBefore, uint256 gasEstimate) private {
        uint256 gasAfter = gasleft();

        uint256 refundValue = _min(
            address(this).balance,
            Bond.actionRefundCap(gasEstimate),
            (Gas.TX + gasBefore - gasAfter)
                * tx.gasprice.min(block.basefee + Bond.REFUND_PRIORITY_FEE_CAP)
        );

        bool status = _tryPayment(msg.sender, refundValue);
        emit PartialBondRefund(msg.sender, refundValue, status);

        _releaseLock();
    }

    /// @dev Skips zero value. A rejected payment returns false instead of
    /// reverting tournament progress.
    function _tryPayment(address recipient, uint256 value)
        private
        returns (bool success)
    {
        if (value == 0) {
            return true;
        }

        uint256 callGas = Bond.PAYMENT_CALL_GAS;
        // Empty input and output ranges send no calldata and copy no return
        // data. A nonzero-value CALL adds a 2,300-gas stipend to `callGas`.
        assembly ("memory-safe") {
            success := call(callGas, recipient, value, 0, 0, 0, 0)
        }
    }

    /// @inheritdoc ITournament
    /// @dev
    /// - ROOT:
    ///     * Reverts with `RequireNonRootTournament` - root tournaments are never eliminated.
    /// - NON-ROOT:
    ///     * Returns true iff:
    ///         1. Tournament finished and has no winner, OR
    ///         2. Tournament finished and enough time elapsed after the winning
    ///            commitment could have won (winner's allowance window).
    function canBeEliminated() public view override returns (bool) {
        TournamentArguments memory args = tournamentArguments();

        if (_isRootTournament(args)) {
            revert RequireNonRootTournament();
        }

        (bool finished, Time.Instant winnerCouldHaveWon) = timeFinished();

        if (!finished) {
            return false;
        }

        (bool _hasDanglingCommitment, Tree.Node _danglingCommitment) =
            hasDanglingCommitment();

        if (!_hasDanglingCommitment) {
            return true;
        }

        (Clock.State memory clock,) = getCommitment(_danglingCommitment);
        return winnerCouldHaveWon.timeoutElapsed(clock.allowance);
    }

    /// @inheritdoc ITournament
    /// @dev
    /// - ROOT:
    ///     * Reverts with `RequireNonRootTournament` - use `arbitrationResult` instead.
    /// - NON-ROOT:
    ///     * Returns:
    ///         - contested parent commitment (from the parent match),
    ///         - winning inner commitment (dangling commitment),
    ///         - adjusted clock of the winner.
    function innerTournamentWinner()
        external
        view
        override
        returns (bool, Tree.Node, Tree.Node, Clock.State memory)
    {
        TournamentArguments memory args = tournamentArguments();

        if (_isRootTournament(args)) {
            revert RequireNonRootTournament();
        }

        if (!isFinished() || canBeEliminated()) {
            Clock.State memory zeroClock;
            return (false, Tree.ZERO_NODE, Tree.ZERO_NODE, zeroClock);
        }

        (bool _hasDanglingCommitment, Tree.Node _winner) =
            hasDanglingCommitment();
        assert(_hasDanglingCommitment);

        (bool finished, Time.Instant finishedTime) = timeFinished();
        assert(finished);

        Clock.State memory _clock = clocks[_winner];
        _clock = _clock.deductPaused(Time.currentTime().timeSpan(finishedTime));

        NestedDispute memory nestedDispute = args.nestedDispute;
        Machine.Hash _finalState = finalStates[_winner];

        if (_finalState.eq(nestedDispute.contestedFinalStateOne)) {
            return (true, nestedDispute.contestedCommitmentOne, _winner, _clock);
        } else {
            assert(_finalState.eq(nestedDispute.contestedFinalStateTwo));
            return (true, nestedDispute.contestedCommitmentTwo, _winner, _clock);
        }
    }

    function getCommitmentJoinedCount()
        external
        view
        override
        returns (uint256)
    {
        return commitmentJoinedCount;
    }

    function getMatchCreatedCount() external view override returns (uint256) {
        return matchCreatedCount;
    }

    function getMatchAdvancedCount() external view override returns (uint256) {
        return matchAdvancedCount;
    }

    function getMatchDeletedCount() external view override returns (uint256) {
        return matchDeletedCount;
    }

    function getNewInnerTournamentCount()
        external
        view
        override
        returns (uint256)
    {
        return newInnerTournamentCount;
    }

    function _ensureTournamentIsNotFinished() private view {
        require(!isFinished(), TournamentIsFinished());
    }

    function _ensureTournamentIsOpen() private view {
        require(!isClosed(), TournamentIsClosed());
    }

    function _emitCommitmentJoined(
        Tree.Node commitment,
        Machine.Hash finalStateHash,
        address submitter
    ) private {
        emit CommitmentJoined(commitment, finalStateHash, submitter);
        ++commitmentJoinedCount;
    }

    function _emitMatchCreated(
        Match.IdHash matchIdHash,
        Tree.Node one,
        Tree.Node two,
        Tree.Node leftOfTwo
    ) private {
        emit MatchCreated(matchIdHash, one, two, leftOfTwo);
        ++matchCreatedCount;
    }

    function _emitMatchAdvanced(
        Match.IdHash matchIdHash,
        Tree.Node otherParent,
        Tree.Node leftNode
    ) private {
        emit MatchAdvanced(matchIdHash, otherParent, leftNode);
        ++matchAdvancedCount;
    }

    function _emitMatchDeleted(
        Match.IdHash matchIdHash,
        Match.Id memory matchId,
        MatchDeletionReason reason,
        WinnerCommitment winnerCommitment
    ) private {
        emit MatchDeleted(
            matchIdHash,
            matchId.commitmentOne,
            matchId.commitmentTwo,
            reason,
            winnerCommitment
        );
        ++matchDeletedCount;
    }

    function _emitNewInnerTournament(
        Match.IdHash matchIdHash,
        ITournament childTournament
    ) private {
        emit NewInnerTournament(matchIdHash, childTournament);
        ++newInnerTournamentCount;
    }
}
