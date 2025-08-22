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
import "prt-contracts/tournament/libs/Weight.sol";

import {Math} from "@openzeppelin-contracts-5.2.0/utils/math/Math.sol";

struct TournamentArgs {
    Machine.Hash initialHash;
    uint256 startCycle;
    uint64 level;
    uint64 levels;
    uint64 log2step;
    uint64 height;
    Time.Instant startInstant;
    Time.Duration allowance;
    Time.Duration maxAllowance;
    Time.Duration matchEffort;
    IDataProvider provider;
}

/// @notice Implements the core functionalities of a permissionless tournament that resolves
/// disputes of n parties in O(log(n))
/// @dev tournaments and matches are nested alternately. Anyone can join a tournament
/// while the tournament is still open, and two of the participants with unique commitments
/// will form a match. A match located in the last level is called `leafMatch`,
/// meaning the one-step disagreement is found and can be resolved by solidity-step.
/// Non-leaf (inner) matches would normally create inner tournaments with height = height + 1,
/// to find the divergence with improved precision.
abstract contract Tournament {
    using Machine for Machine.Hash;
    using Tree for Tree.Node;
    using Commitment for Tree.Node;

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
    // MEV tips
    uint256 constant MEV_PROFIT = 10 gwei;
    bool transient locked;

    mapping(Tree.Node => Clock.State) clocks;
    mapping(Tree.Node => Machine.Hash) finalStates;
    mapping(Tree.Node => address) claimers;
    // matches existing in current tournament
    mapping(Match.IdHash => Match.State) matches;

    //
    // Events
    //
    event matchCreated(
        Tree.Node indexed one, Tree.Node indexed two, Tree.Node leftOfTwo
    );
    event matchDeleted(Match.IdHash);
    event commitmentJoined(Tree.Node root);

    //
    // Errors
    //
    error InsufficientBond();
    error NoWinner();
    error TournamentIsFinished();
    error TournamentNotFinished();
    error TournamentIsClosed();
    error ReentrancyDetected();

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
    modifier refundable(uint256 weight) {
        require(!locked, ReentrancyDetected());
        locked = true;

        uint256 gasBefore = gasleft();
        _;
        uint256 gasAfter = gasleft();

        uint256 refundValue = _min(
            address(this).balance,
            bondValue() * weight / _interactionsWeight(),
            (Weight.TX_INTRINSIC_GAS + gasBefore - gasAfter)
                * (tx.gasprice + MEV_PROFIT)
        );
        msg.sender.call{value: refundValue}("");

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

    //
    // Methods
    //
    function bondValue() public view returns (uint256) {
        return _interactionsWeight() * MAX_GAS_PRICE;
    }

    /// @dev root tournaments are open to everyone,
    /// while non-root tournaments are open to anyone
    /// who's final state hash matches the one of the two in the tournament
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external payable tournamentOpen {
        require(msg.value >= bondValue(), InsufficientBond());

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);

        TournamentArgs memory args = _tournamentArgs();

        // Prove final state is in commitmentRoot
        _commitmentRoot.requireFinalState(args.height, _finalState, _proof);

        // Verify whether finalState is one of the two allowed of tournament if nested
        requireValidContestedFinalState(_finalState);
        finalStates[_commitmentRoot] = _finalState;

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireNotInitialized(); // reverts if commitment is duplicate
        _clock.setNewPaused(args.startInstant, args.allowance);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);
        emit commitmentJoined(_commitmentRoot);

        claimers[_commitmentRoot] = msg.sender;
    }

    /// @notice Advance the match until the smallest divergence is found at current level
    /// @dev this function is being called repeatedly in turns by the two parties that disagree on the commitment.
    function advanceMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Tree.Node _newLeftNode,
        Tree.Node _newRightNode
    ) external refundable(Weight.ADVANCE_MATCH) tournamentNotFinished {
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

    error WrongChildren(
        uint256 commitment, Tree.Node parent, Tree.Node left, Tree.Node right
    );
    error WinByTimeout();

    function winMatchByTimeout(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external refundable(Weight.WIN_MATCH_BY_TIMEOUT) tournamentNotFinished {
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
        } else {
            revert WinByTimeout();
        }

        // delete storage
        deleteMatch(_matchId.hashFromId());
    }

    error EliminateByTimeout();

    function eliminateMatchByTimeout(Match.Id calldata _matchId)
        external
        refundable(Weight.ELIMINATE_MATCH_BY_TIMEOUT)
        tournamentNotFinished
    {
        matches[_matchId.hashFromId()].requireExist();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        // check if both clocks are out of time
        if (
            (
                !_clockOne.hasTimeLeft()
                    && !_clockTwo.timeLeft().gt(_clockOne.timeSinceTimeout())
            )
                || (
                    !_clockTwo.hasTimeLeft()
                        && !_clockOne.timeLeft().gt(_clockTwo.timeSinceTimeout())
                )
        ) {
            // delete storage
            deleteMatch(_matchId.hashFromId());

            // clear the claimer for both commitments
            delete claimers[_matchId.commitmentOne];
            delete claimers[_matchId.commitmentTwo];
        } else {
            revert EliminateByTimeout();
        }
    }

    //
    // View methods
    //
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
        uint256 startCycle = _tournamentArgs().startCycle;
        return _m.toCycle(startCycle);
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
        TournamentArgs memory args;
        args = _tournamentArgs();
        _maxLevel = args.levels;
        _level = args.level;
        _log2step = args.log2step;
        _height = args.height;
    }

    //
    // Helper functions
    //
    error InvalidContestedFinalState(
        Machine.Hash contestedFinalStateOne,
        Machine.Hash contestedFinalStateTwo,
        Machine.Hash finalState
    );

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

    function setDanglingCommitment(Tree.Node _node) internal {
        danglingCommitment = _node;
    }

    function clearDanglingCommitment() internal {
        danglingCommitment = Tree.ZERO_NODE;
    }

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
            TournamentArgs memory args = _tournamentArgs();
            (Match.IdHash _matchId, Match.State memory _matchState) = Match
                .createMatch(
                _danglingCommitment,
                _rootHash,
                _leftNode,
                _rightNode,
                args.log2step,
                args.height
            );

            matches[_matchId] = _matchState;

            Clock.State storage _firstClock = clocks[_danglingCommitment];

            // grant extra match effort for both clocks
            _firstClock.addMatchEffort(args.matchEffort, args.maxAllowance);
            _newClock.addMatchEffort(args.matchEffort, args.maxAllowance);

            _firstClock.advanceClock();

            clearDanglingCommitment();
            matchCount++;

            emit matchCreated(_danglingCommitment, _rootHash, _leftNode);
        } else {
            setDanglingCommitment(_rootHash);
        }
    }

    function deleteMatch(Match.IdHash _matchIdHash) internal {
        matchCount--;
        lastMatchDeleted = Time.currentTime();
        delete matches[_matchIdHash];
        emit matchDeleted(_matchIdHash);
    }

    //
    // Clock methods
    //

    /// @return bool if the tournament is still open to join
    function isClosed() public view returns (bool) {
        Time.Instant startInstant;
        Time.Duration allowance;
        {
            TournamentArgs memory args;
            args = _tournamentArgs();
            startInstant = args.startInstant;
            allowance = args.allowance;
        }
        return startInstant.timeoutElapsed(allowance);
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

        TournamentArgs memory args = _tournamentArgs();

        // Here, we know that `lastMatchDeleted` holds the Instant when `matchCount` became zero.
        // However, we still must consider when the tournament was closed, in case it
        // happens after `lastMatchDeleted`.
        // Note that `lastMatchDeleted` could be zero if there are no matches eliminated.
        // In this case, we'd only care about `tournamentClosed`.
        Time.Instant tournamentClosed = args.startInstant.add(args.allowance);
        Time.Instant winnerCouldWin = tournamentClosed.max(lastMatchDeleted);

        return (true, winnerCouldWin);
    }

    function tryRecoverBond() external {
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
        winner.call{value: contractBalance}("");

        // clear the claimer for the winning commitment
        delete claimers[winningCommitment];
    }

    //
    // Internal functions
    //
    function _tournamentArgs()
        internal
        view
        virtual
        returns (TournamentArgs memory);

    function _interactionsWeight() internal view virtual returns (uint256);

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
