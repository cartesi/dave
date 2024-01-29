// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../CanonicalConstants.sol";

import "../../Commitment.sol";
import "../../Time.sol";
import "../../Machine.sol";
import "../../Tree.sol";
import "../../Clock.sol";
import "../../Match.sol";

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
    // Constants
    //
    Machine.Hash immutable initialHash;

    uint256 immutable startCycle;
    uint64 immutable level;

    Time.Instant immutable startInstant;
    Time.Duration immutable allowance;

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
    event commitmentJoined(Tree.Node root);

    //
    // Modifiers
    //
    modifier tournamentNotFinished() {
        require(!isFinished(), "tournament is finished");

        _;
    }

    modifier tournamentOpen() {
        require(!isClosed(), "tournament check-in elapsed");

        _;
    }

    //
    // Constructor
    //
    constructor(
        Machine.Hash _initialHash,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) {
        initialHash = _initialHash;
        startCycle = _startCycle;
        level = _level;
        startInstant = Time.currentTime();
        allowance = _allowance;

        if (_allowance.gt(ArbitrationConstants.MAX_ALLOWANCE)) {
            _allowance = ArbitrationConstants.MAX_ALLOWANCE;
        }
    }

    //
    // Virtual Methods
    //

    /// @return bool if commitment with _finalState is allowed to join the tournament
    function validContestedFinalState(Machine.Hash _finalState)
        internal
        view
        virtual
        returns (bool);

    //
    // Methods
    //

    /// @dev root tournaments are open to everyone, while non-root tournaments are open to anyone who's final state hash matches the one of the two in the tournament
    function joinTournament(
        Machine.Hash _finalState,
        bytes32[] calldata _proof,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external tournamentOpen {
        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);

        // Prove final state is in commitmentRoot
        _commitmentRoot.requireFinalState(level, _finalState, _proof);

        // Verify whether finalState is one of the two allowed of tournament if nested
        requireValidContestedFinalState(_finalState);
        finalStates[_commitmentRoot] = _finalState;

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireNotInitialized(); // reverts if commitment is duplicate
        _clock.setNewPaused(startInstant, allowance);

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
        _matchState.requireParentHasChildren(_leftNode, _rightNode);

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
    ) external tournamentNotFinished {
        matches[_matchId.hashFromId()].requireExist();
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];

        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        if (_clockOne.hasTimeLeft() && !_clockTwo.hasTimeLeft()) {
            require(
                _matchId.commitmentOne.verify(_leftNode, _rightNode),
                "child nodes do not match parent (commitmentOne)"
            );

            _clockOne.deduct(_clockTwo.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentOne, _clockOne, _leftNode, _rightNode
            );
        } else if (!_clockOne.hasTimeLeft() && _clockTwo.hasTimeLeft()) {
            require(
                _matchId.commitmentTwo.verify(_leftNode, _rightNode),
                "child nodes do not match parent (commitmentTwo)"
            );

            _clockTwo.deduct(_clockOne.timeSinceTimeout());
            pairCommitment(
                _matchId.commitmentTwo, _clockTwo, _leftNode, _rightNode
            );
        } else {
            revert("cannot win by timeout");
        }

        // delete storage
        deleteMatch(_matchId.hashFromId());
    }

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
            revert("cannot eliminate by timeout");
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

    // TODO: do we need this?
    function getMatchCycle(Match.IdHash _matchIdHash)
        external
        view
        returns (uint256)
    {
        Match.State memory _m = getMatch(_matchIdHash);
        return _m.toCycle(startCycle);
    }

    function tournamentLevelConstants()
        external
        view
        returns (uint64 _max_level, uint64 _level, uint64 _log2step, uint64 _height)
    {
        _max_level = ArbitrationConstants.LEVELS;
        _level = level;
        _log2step = ArbitrationConstants.log2step(level);
        _height = ArbitrationConstants.height(level);
    }

    //
    // Helper functions
    //
    function requireValidContestedFinalState(Machine.Hash _finalState)
        internal
        view
    {
        require(
            validContestedFinalState(_finalState),
            "tournament doesn't have contested final state"
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
            (Match.IdHash _matchId, Match.State memory _matchState) = Match
                .createMatch(
                _danglingCommitment, _rootHash, _leftNode, _rightNode, level
            );

            matches[_matchId] = _matchState;

            Clock.State storage _firstClock = clocks[_danglingCommitment];

            // grant extra match effort for both clocks
            _firstClock.addMatchEffort();
            _newClock.addMatchEffort();

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
    }

    //
    // Clock methods
    //

    /// @return bool if the tournament is still open to join
    function isClosed() internal view returns (bool) {
        return startInstant.timeoutElapsed(allowance);
    }

    /// @return bool if the tournament is over
    function isFinished() internal view returns (bool) {
        return isClosed() && matchCount == 0;
    }
}
