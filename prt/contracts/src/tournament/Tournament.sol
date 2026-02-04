// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";
import {Math} from "@openzeppelin-contracts-5.5.0/utils/math/Math.sol";
import {IERC165} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/IMultiLevelTournamentFactory.sol";
import {ITournament} from "prt-contracts/tournament/ITournament.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Gas} from "prt-contracts/tournament/libs/Gas.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @title Tournament — Asynchronous PRT-style dispute resolution
/// @notice Core, permissionless tournament that resolves disputes among
/// N parties in O(log N) depth under chess-clock timing. Pairing is asynchronous:
/// claims are matched as they arrive (or when winners re-enter), without a
/// prebuilt bracket.
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
///   * Always created by a parent tournament via
///     `sealInnerMatchAndCreateInnerTournament`.
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

    /// @notice Total gas estimate used to size the tournament bond.
    /// @dev Includes:
    ///  - ADVANCE_MATCH across tree height (common to all levels),
    ///  - Leaf operations (seal + win),
    ///  - Inner operations (seal + win).
    /// The extra term is chosen as max(leaf, inner) to keep a single,
    /// safe bond size across root / inner / leaf tournaments.
    function _totalGasEstimate() internal view returns (uint256) {
        TournamentArguments memory args = tournamentArguments();
        uint256 base = Gas.ADVANCE_MATCH * args.commitmentArgs.height;
        uint256 leafPart = Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH;
        uint256 innerPart = Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            + Gas.WIN_INNER_TOURNAMENT;
        uint256 extra = leafPart > innerPart ? leafPart : innerPart;
        return base + extra;
    }

    //
    // Methods
    //

    function bondValue() public view override returns (uint256) {
        return _totalGasEstimate() * MAX_GAS_PRICE;
    }

    /// @notice Join a tournament (root or inner) with a commitment.
    /// @dev
    /// - ROOT (level == 0):
    ///     * Open to all final states, contested fields in TournamentArguments are zero.
    /// - NON-ROOT (level > 0):
    ///     * Final state must match one of the two contested final states.
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external payable override tournamentOpen {
        require(msg.value >= bondValue(), InsufficientBond());

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);

        TournamentArguments memory args = tournamentArguments();

        _commitmentRoot.requireFinalState(
            args.commitmentArgs.height, _finalState, _proof
        );

        requireValidContestedFinalState(_finalState);
        finalStates[_commitmentRoot] = _finalState;

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireNotInitialized();
        _clock.setNewPaused(args.startInstant, args.allowance);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);
        claimers[_commitmentRoot] = msg.sender;
        emit CommitmentJoined(_commitmentRoot, _finalState, msg.sender);
    }

    /// @inheritdoc ITournament
    function advanceMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Tree.Node _newLeftNode,
        Tree.Node _newRightNode
    ) external override refundable(Gas.ADVANCE_MATCH) tournamentNotFinished {
        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireCanBeAdvanced();

        _matchState.advanceMatch(
            _matchId, _leftNode, _rightNode, _newLeftNode, _newRightNode
        );

        clocks[_matchId.commitmentOne].advanceClock();
        clocks[_matchId.commitmentTwo].advanceClock();
    }

    /// @notice Win a match by timeout at any level (root or inner).
    /// @dev
    /// - Behavior is identical for root and inner tournaments; level only affects
    ///   how the winner is later interpreted by parent tournaments.
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
        override
        refundable(Gas.ELIMINATE_MATCH_BY_TIMEOUT)
        tournamentNotFinished
    {
        matches[_matchId.hashFromId()].requireExist();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

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

    /// @notice Try to recover the bond of the winning commitment submitter.
    /// @dev
    /// - ROOT:
    ///     * Winner is the root tournament winner.
    /// - NON-ROOT:
    ///     * Winner is the inner winner that will be used by the parent tournament.
    function tryRecoveringBond() public override returns (bool) {
        require(isFinished(), TournamentNotFinished());

        (bool hasDangling, Tree.Node winningCommitment) =
            hasDanglingCommitment();
        require(hasDangling, NoWinner());

        address winner = claimers[winningCommitment];
        assert(winner != address(0));

        uint256 contractBalance = address(this).balance;
        (bool success,) = winner.call{value: contractBalance}("");

        if (success) {
            deleteClaimer(winningCommitment);
        }

        return success;
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
        _matchState.requireExist();
        _matchState.requireCanBeFinalized();

        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _clock1.setPaused();
            _clock1.advanceClock();
            _clock2.setPaused();
            _clock2.advanceClock();
        }

        _matchState.sealMatch(
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

        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];
        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        (
            Machine.Hash _agreeHash,
            uint256 _agreeCycle,
            Machine.Hash _finalStateOne,
            Machine.Hash _finalStateTwo
        ) = _matchState.getDivergence(args.commitmentArgs);

        IStateTransition stateTransition = _tournamentArgs().stateTransition;
        Machine.Hash _finalState = Machine.Hash
            .wrap(
                stateTransition.transitionState(
                    Machine.Hash.unwrap(_agreeHash),
                    _agreeCycle,
                    proofs,
                    args.provider
                )
            );

        if (_leftNode.join(_rightNode).eq(_matchId.commitmentOne)) {
            require(
                _finalState.eq(_finalStateOne),
                WrongFinalState(1, _finalState, _finalStateOne)
            );

            _clockOne.setPaused();
            pairCommitment(
                _matchId.commitmentOne, _clockOne, _leftNode, _rightNode
            );

            deleteMatch(
                _matchId, MatchDeletionReason.STEP, WinnerCommitment.ONE
            );
        } else if (_leftNode.join(_rightNode).eq(_matchId.commitmentTwo)) {
            require(
                _finalState.eq(_finalStateTwo),
                WrongFinalState(2, _finalState, _finalStateTwo)
            );

            _clockTwo.setPaused();
            pairCommitment(
                _matchId.commitmentTwo, _clockTwo, _leftNode, _rightNode
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
        _matchState.requireCanBeFinalized();

        Time.Duration _maxDuration;
        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _clock1.setPaused();
            _clock2.setPaused();
            _maxDuration = Clock.max(_clock1, _clock2);
        }

        (Machine.Hash _finalStateOne, Machine.Hash _finalStateTwo) = _matchState.sealMatch(
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
            _matchState.toCycle(args.commitmentArgs),
            args.level + 1
        );
        matchIdFromInnerTournaments[_inner] = _matchId;

        emit NewInnerTournament(_matchId.hashFromId(), _inner);
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
        _matchIdHash.requireExist();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        require(
            !_childTournament.canBeEliminated(),
            ChildTournamentMustBeEliminated()
        );

        (bool finished, Tree.Node _winner,, Clock.State memory _innerClock) =
            _childTournament.innerTournamentWinner();
        require(finished, ChildTournamentNotFinished());
        _winner.requireExist();

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);
        require(
            _commitmentRoot.eq(_winner),
            WrongTournamentWinner(_commitmentRoot, _winner)
        );

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireInitialized();
        _clock.reInitialized(_innerClock);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);

        WinnerCommitment _winnerCommitment;

        if (_winner.eq(_matchId.commitmentOne)) {
            _winnerCommitment = WinnerCommitment.ONE;
        } else if (_winner.eq(_matchId.commitmentTwo)) {
            _winnerCommitment = WinnerCommitment.TWO;
        } else {
            revert InvalidTournamentWinner(_winner);
        }

        deleteMatch(
            _matchId, MatchDeletionReason.CHILD_TOURNAMENT, _winnerCommitment
        );
        delete matchIdFromInnerTournaments[_childTournament];

        _childTournament.tryRecoveringBond();
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
        _matchIdHash.requireExist();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExist();
        _matchState.requireIsFinished();

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
        Clock.State memory _clockOne = clocks[_matchId.commitmentOne];
        Clock.State memory _clockTwo = clocks[_matchId.commitmentTwo];

        return !_clockOne.hasTimeLeft() || !_clockTwo.hasTimeLeft();
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
        Match.State memory _m = getMatch(_matchIdHash);
        Commitment.Arguments memory args = tournamentArguments().commitmentArgs;

        return args.toCycle(_m.runningLeafPosition);
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
    ///     * Used to measure bond recovery and elimination windows when acting
    ///       as an inner tournament of a hypothetical higher level.
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

    /// @notice Get the root tournament's final result.
    /// @dev
    /// - ROOT ONLY (level == 0):
    ///     * Returns the winner commitment and its final state once finished.
    /// - NON-ROOT:
    ///     * Not used; parents call `innerTournamentWinner` instead.
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

    /// @inheritdoc ITask
    function result()
        external
        view
        override
        returns (bool finished, Machine.Hash finalState)
    {
        (finished,, finalState) = this.arbitrationResult();
    }

    /// @inheritdoc ITask
    /// @dev Best-effort bond recovery for finished tournaments.
    function cleanup() external override returns (bool cleaned) {
        if (!isFinished()) {
            return false;
        }

        try this.tryRecoveringBond() returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function supportsInterface(bytes4 interfaceId)
        external
        view
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ITask).interfaceId
            || interfaceId == type(ITournament).interfaceId;
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
    /// new commitment. Otherwise, stores the new commitment as dangling.
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

            _firstClock.addMatchEffort(args.matchEffort, args.maxAllowance);
            _newClock.addMatchEffort(args.matchEffort, args.maxAllowance);

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

    function _min(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256)
    {
        return a.min(b).min(c);
    }

    function _refundableBefore() private returns (uint256 gasBefore) {
        require(!locked, ReentrancyDetected());
        locked = true;
        gasBefore = gasleft();
    }

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
        emit PartialBondRefund(msg.sender, refundValue, status, ret);

        locked = false;
    }

    /// @inheritdoc ITournament
    /// @dev
    /// - ROOT:
    ///     * Reverts with `RequireNonRootTournament` — root tournaments are never eliminated.
    /// - NON-ROOT:
    ///     * Returns true iff:
    ///         1. Tournament finished and has no winner, OR
    ///         2. Tournament finished and enough time elapsed after the winning
    ///            commitment could have won (winner's allowance window).
    function canBeEliminated() external view override returns (bool) {
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
    ///     * Reverts with `RequireNonRootTournament` — use `arbitrationResult` instead.
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

        if (!isFinished() || this.canBeEliminated()) {
            Clock.State memory zeroClock;
            return (false, Tree.ZERO_NODE, Tree.ZERO_NODE, zeroClock);
        }

        (bool _hasDanglingCommitment, Tree.Node _winner) =
            hasDanglingCommitment();
        assert(_hasDanglingCommitment);

        (bool finished, Time.Instant finishedTime) = timeFinished();
        assert(finished);

        Clock.State memory _clock = clocks[_winner];
        _clock = _clock.deduct(Time.currentTime().timeSpan(finishedTime));

        NestedDispute memory nestedDispute = args.nestedDispute;
        Machine.Hash _finalState = finalStates[_winner];

        if (_finalState.eq(nestedDispute.contestedFinalStateOne)) {
            return (true, nestedDispute.contestedCommitmentOne, _winner, _clock);
        } else {
            assert(_finalState.eq(nestedDispute.contestedFinalStateTwo));
            return (true, nestedDispute.contestedCommitmentTwo, _winner, _clock);
        }
    }

    function _ensureTournamentIsNotFinished() private view {
        require(!isFinished(), TournamentIsFinished());
    }

    function _ensureTournamentIsOpen() private view {
        require(!isClosed(), TournamentIsClosed());
    }
}
