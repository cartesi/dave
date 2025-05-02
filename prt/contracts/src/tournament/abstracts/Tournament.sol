// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/arbitration-config/CanonicalConstants.sol";
import "prt-contracts/IDataProvider.sol";
import "prt-contracts/types/TournamentParameters.sol";
import "prt-contracts/types/Machine.sol";
import "prt-contracts/types/Tree.sol";

import "prt-contracts/tournament/libs/Commitment.sol";
import "prt-contracts/tournament/libs/Time.sol";
import "prt-contracts/tournament/libs/Clock.sol";
import "prt-contracts/tournament/libs/Match.sol";

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

    //
    // Storage
    //
    Tree.Node danglingCommitment;
    uint256 matchCount;

    mapping(Tree.Node => Clock.State) clocks;
    mapping(Tree.Node => Machine.Hash) finalStates;
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
    // Modifiers
    //
    error TournamentIsFinished();
    error TournamentIsClosed();

    modifier tournamentNotFinished() {
        require(!isFinished(), TournamentIsFinished());

        _;
    }

    modifier tournamentOpen() {
        require(!isClosed(), TournamentIsClosed());

        _;
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

    /// @dev root tournaments are open to everyone,
    /// while non-root tournaments are open to anyone
    /// who's final state hash matches the one of the two in the tournament
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external tournamentOpen {
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
    }

    /// @notice Advance the match until the smallest divergence is found at current level
    /// @dev this function is being called repeatedly in turns by the two parties that disagree on the commitment.
    function advanceMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        Tree.Node _newLeftNode,
        Tree.Node _newRightNode
    ) external tournamentNotFinished {
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
    ) external tournamentNotFinished {
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

            _clockOne.deduct(_clockTwo.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentOne, _clockOne, _leftNode, _rightNode
            );
        } else if (!_clockOne.hasTimeLeft() && _clockTwo.hasTimeLeft()) {
            require(
                _matchId.commitmentTwo.verify(_leftNode, _rightNode),
                WrongChildren(2, _matchId.commitmentTwo, _leftNode, _rightNode)
            );

            _clockTwo.deduct(_clockOne.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentTwo, _clockTwo, _leftNode, _rightNode
            );
        } else {
            revert WinByTimeout();
        }

        // delete storage
        deleteMatch(_matchId.hashFromId());
    }

    error EliminateByTimeout();

    function eliminateMatchByTimeout(Match.Id calldata _matchId)
        external
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
        external
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
        delete matches[_matchIdHash];
        emit matchDeleted(_matchIdHash);
    }

    //
    // Clock methods
    //

    /// @return bool if the tournament is still open to join
    function isClosed() internal view returns (bool) {
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
    function isFinished() internal view returns (bool) {
        return isClosed() && matchCount == 0;
    }

    //
    // Internal functions
    //
    function _tournamentArgs()
        internal
        view
        virtual
        returns (TournamentArgs memory);
}
