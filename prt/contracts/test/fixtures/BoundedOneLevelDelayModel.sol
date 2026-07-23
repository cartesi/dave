// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

/// @notice Finite, discrete-time model of one leaf-level tournament.
/// @dev This is a test fixture, not an unbounded liveness theorem. It explores
/// every join time, valid bisection response time, and same-block action order
/// for at most six distinct claims. Permissionless timeout cleanup is assumed
/// to happen in the first eligible block: while any match can time out, other
/// same-block actions may execute, but the model cannot advance time.
/// Before timeout, objective leaf proofs branch on whether the low- or
/// high-allowance side is correct. Equal branches are collapsed. Once either
/// leaf clock expires, proof settlement is no longer available and the timeout
/// action owns resolution.
/// All participant responses are scheduler-controlled; the model does not
/// designate an honest commitment or impose an honest proof strategy. Each
/// proof may independently choose either side, deliberately forgetting the
/// cross-match correctness correlation of a real commitment. The result is a
/// clock-only upper envelope, not an exact one-honest adversarial strategy.
///
/// For clock transitions, claims are otherwise symmetric. A dangling clock is
/// kept separately; active matches form a sorted multiset. In a bisection
/// record, clock one is running and clock two is paused. In a leaf-race record,
/// the allowances are sorted because both clocks share one start instant;
/// explicit low/high proof actions retain both clock outcomes. Instants are
/// relative to tournament creation, so zero is a valid match start here; phase
/// is encoded separately rather than overloaded onto that instant.
contract BoundedOneLevelDelayModel {
    uint8 internal constant MAX_CLAIMS = 6;
    uint8 internal constant MAX_ALLOWANCE = 4;
    uint8 internal constant MAX_RESPONSE_BUDGET = 2;
    uint8 internal constant MAX_HEIGHT = 3;
    uint8 internal constant MAX_MATCHES = MAX_CLAIMS / 2;

    uint8 internal constant INVALID_COMPLETION = type(uint8).max;

    // Packed state, low to high: current[7], unjoined[3], dangling[3],
    // matchCount[2], matches[3 * 16]. Packed match, low to high:
    // responsesRemaining[2], allowanceOne[3], allowanceTwo[3], start[7], pad[1].
    uint8 internal constant TIME_BITS = 7;
    uint8 internal constant UNJOINED_SHIFT = TIME_BITS;
    uint8 internal constant DANGLING_SHIFT = UNJOINED_SHIFT + 3;
    uint8 internal constant MATCH_COUNT_SHIFT = DANGLING_SHIFT + 3;
    uint8 internal constant MATCHES_SHIFT = MATCH_COUNT_SHIFT + 2;
    uint8 internal constant MATCH_BITS = 16;

    uint256 internal constant TIME_MASK = (uint256(1) << TIME_BITS) - 1;
    uint256 internal constant THREE_BIT_MASK = 7;
    uint256 internal constant TWO_BIT_MASK = 3;
    uint256 internal constant MATCH_MASK = type(uint16).max;

    enum ActionKind {
        NONE,
        JOIN,
        RESPOND,
        TIMEOUT,
        WAIT,
        PROVE_LOW,
        PROVE_HIGH
    }

    struct Configuration {
        uint8 claims;
        uint8 allowance;
        uint8 responseBudget;
        uint8 height;
    }

    struct StateView {
        uint8 current;
        uint8 unjoined;
        uint8 danglingAllowance;
        uint8 matchCount;
    }

    struct MatchView {
        uint8 responsesRemaining;
        uint8 allowanceOne;
        uint8 allowanceTwo;
        uint8 startInstant;
    }

    struct Witness {
        uint64[] states;
        uint8[] actions;
    }

    error ConfigurationOutsideModelBounds();
    error SolverInvariant();

    // A zero memo value means unseen. Valid completions are stored plus one;
    // the invalid sentinel is stored as 256.
    mapping(uint256 key => uint16 completionPlusOne) private memoizedCompletion;
    mapping(uint16 transitionConfiguration => uint256 count) private
        visitedStateCount;

    function solve(Configuration memory config)
        public
        returns (uint8 completion, uint256 statesVisited)
    {
        _requireSupported(config);
        uint16 configId = _configurationId(config);
        completion = _maximumCompletion(configId, _initialState(config.claims));
        if (completion == INVALID_COMPLETION) revert SolverInvariant();
        statesVisited = visitedStateCount[configId];
    }

    /// @notice Reconstruct one deterministic schedule attaining the maximum.
    /// @dev `solve` must be called for this configuration first. Each action at
    /// index i transforms states[i] into states[i + 1]. The final state has no
    /// action. Match-index actions refer to the canonical match ordering in the
    /// corresponding state.
    function witness(Configuration memory config)
        public
        view
        returns (Witness memory result)
    {
        _requireSupported(config);
        uint16 configId = _configurationId(config);
        uint64 state = _initialState(config.claims);
        uint256 length;

        while (!_isTerminal(state, config.allowance)) {
            uint8 action = _selectedAction(state, configId);
            state = _applySelectedAction(state, configId, action);
            ++length;
        }

        result.states = new uint64[](length + 1);
        result.actions = new uint8[](length);
        state = _initialState(config.claims);
        result.states[0] = state;
        for (uint256 i; i < length; ++i) {
            uint8 action = _selectedAction(state, configId);
            result.actions[i] = action;
            state = _applySelectedAction(state, configId, action);
            result.states[i + 1] = state;
        }
    }

    function actionKind(uint8 action) public pure returns (ActionKind) {
        return ActionKind(action >> 2);
    }

    function actionMatchIndex(uint8 action) public pure returns (uint8) {
        return action & 3;
    }

    function inspectState(uint64 state)
        public
        pure
        returns (StateView memory view_)
    {
        return _inspectState(state);
    }

    function inspectMatch(uint64 state, uint8 index)
        public
        pure
        returns (MatchView memory view_)
    {
        uint8 count = _matchCount(state);
        if (index >= count) revert SolverInvariant();
        return _inspectMatch(_matchAt(state, index));
    }

    function _maximumCompletion(uint16 configId, uint64 state)
        private
        returns (uint8 maximum)
    {
        uint256 key = _key(configId, state);
        uint16 cached = memoizedCompletion[key];
        if (cached != 0) return _decodeCompletion(cached);

        ++visitedStateCount[configId];

        uint8 current = _current(state);
        uint8 unjoined = _unjoined(state);
        uint8 allowance = _configuredAllowance(configId);
        uint8 count = _matchCount(state);
        if (current >= allowance && unjoined != 0) {
            _memoize(key, INVALID_COMPLETION);
            return INVALID_COMPLETION;
        }
        if (unjoined == 0 && count == 0) {
            maximum = current > allowance ? current : allowance;
            _memoize(key, maximum);
            return maximum;
        }

        maximum = 0;
        bool found;

        if (unjoined != 0 && current < allowance) {
            (maximum, found) =
                _consider(configId, _join(state, configId), maximum, found);
        }

        bool hasTimeout;
        uint16 previousMatch;
        for (uint8 i; i < count; ++i) {
            uint16 match_ = _matchAt(state, i);
            if (i != 0 && match_ == previousMatch) continue;
            previousMatch = match_;

            bool timedOut = _isTimedOut(match_, current);
            if (timedOut) {
                hasTimeout = true;
                (maximum, found) = _consider(
                    configId, _timeout(state, configId, i), maximum, found
                );
            } else if (_responsesRemaining(match_) != 0) {
                (maximum, found) = _consider(
                    configId, _respond(state, configId, i), maximum, found
                );
            } else {
                (maximum, found) = _consider(
                    configId, _prove(state, configId, i, false), maximum, found
                );
                if (_allowanceOne(match_) != _allowanceTwo(match_)) {
                    (maximum, found) = _consider(
                        configId,
                        _prove(state, configId, i, true),
                        maximum,
                        found
                    );
                }
            }
        }

        if (!hasTimeout) {
            if (current == TIME_MASK) revert SolverInvariant();
            (maximum, found) = _consider(
                configId, _setCurrent(state, current + 1), maximum, found
            );
        }

        if (!found) {
            _memoize(key, INVALID_COMPLETION);
            return INVALID_COMPLETION;
        }
        _memoize(key, maximum);
    }

    function _selectedAction(uint64 state, uint16 configId)
        private
        view
        returns (uint8)
    {
        uint8 target = _memoizedCompletion(configId, state);
        uint8 current = _current(state);
        uint8 unjoined = _unjoined(state);
        uint8 allowance = _configuredAllowance(configId);
        uint8 count = _matchCount(state);

        if (unjoined != 0 && current < allowance) {
            uint64 joined = _join(state, configId);
            if (_memoizedCompletion(configId, joined) == target) {
                return _encodeAction(ActionKind.JOIN, 0);
            }
        }

        bool hasTimeout;
        uint16 previousMatch;
        for (uint8 i; i < count; ++i) {
            uint16 match_ = _matchAt(state, i);
            if (i != 0 && match_ == previousMatch) continue;
            previousMatch = match_;

            bool timedOut = _isTimedOut(match_, current);
            if (timedOut) {
                hasTimeout = true;
                if (
                    _memoizedCompletion(configId, _timeout(state, configId, i))
                        == target
                ) {
                    return _encodeAction(ActionKind.TIMEOUT, i);
                }
            } else if (
                _responsesRemaining(match_) != 0
                    && _memoizedCompletion(
                            configId, _respond(state, configId, i)
                        ) == target
            ) {
                return _encodeAction(ActionKind.RESPOND, i);
            } else if (_responsesRemaining(match_) == 0) {
                if (
                    _memoizedCompletion(
                            configId, _prove(state, configId, i, false)
                        ) == target
                ) {
                    return _encodeAction(ActionKind.PROVE_LOW, i);
                }
                if (
                    _allowanceOne(match_) != _allowanceTwo(match_)
                        && _memoizedCompletion(
                                configId, _prove(state, configId, i, true)
                            ) == target
                ) {
                    return _encodeAction(ActionKind.PROVE_HIGH, i);
                }
            }
        }

        if (!hasTimeout) {
            uint64 waited = _setCurrent(state, current + 1);
            if (_memoizedCompletion(configId, waited) == target) {
                return _encodeAction(ActionKind.WAIT, 0);
            }
        }
        revert SolverInvariant();
    }

    function _consider(
        uint16 configId,
        uint64 nextState,
        uint8 maximum,
        bool found
    ) private returns (uint8, bool) {
        uint8 candidate = _maximumCompletion(configId, nextState);
        if (candidate != INVALID_COMPLETION && (!found || candidate > maximum))
        {
            return (candidate, true);
        }
        return (maximum, found);
    }

    function _join(uint64 state, uint16 configId)
        private
        pure
        returns (uint64)
    {
        uint8 current = _current(state);
        uint8 unjoined = _unjoined(state);
        uint8 configuredAllowance = _configuredAllowance(configId);
        uint8 dangling = _dangling(state);
        assert(unjoined != 0 && current < configuredAllowance);
        uint8 allowance = configuredAllowance - current;
        state = _setUnjoined(state, unjoined - 1);

        if (dangling == 0) {
            return _setDangling(state, allowance);
        }

        state = _setDangling(state, 0);
        return _insertMatch(
            state,
            _encodeMatch(
                _configuredHeight(configId), dangling, allowance, current
            )
        );
    }

    function _respond(uint64 state, uint16 configId, uint8 matchIndex)
        private
        pure
        returns (uint64)
    {
        uint8 current = _current(state);
        uint16 match_ = _matchAt(state, matchIndex);
        uint8 responses = _responsesRemaining(match_);
        uint8 allowanceOne = _allowanceOne(match_);
        uint8 allowanceTwo = _allowanceTwo(match_);
        assert(responses != 0);

        uint8 elapsed = current - _startInstant(match_);
        assert(elapsed < allowanceOne);
        uint8 responseBudget = _configuredResponseBudget(configId);
        uint8 charge = elapsed > responseBudget ? elapsed - responseBudget : 0;
        uint8 pausedAllowance = allowanceOne - charge;

        uint16 replacement;
        if (responses == 1) {
            uint8 low =
                pausedAllowance < allowanceTwo ? pausedAllowance : allowanceTwo;
            uint8 high =
                pausedAllowance < allowanceTwo ? allowanceTwo : pausedAllowance;
            replacement = _encodeMatch(0, low, high, current);
        } else {
            replacement = _encodeMatch(
                responses - 1, allowanceTwo, pausedAllowance, current
            );
        }
        return _replaceMatch(state, matchIndex, replacement);
    }

    function _timeout(uint64 state, uint16 configId, uint8 matchIndex)
        private
        pure
        returns (uint64)
    {
        uint8 current = _current(state);
        uint16 match_ = _matchAt(state, matchIndex);
        assert(_isTimedOut(match_, current));

        uint8 survivorAllowance;
        uint8 elapsed = current - _startInstant(match_);
        uint8 allowanceOne = _allowanceOne(match_);
        uint8 allowanceTwo = _allowanceTwo(match_);
        if (_responsesRemaining(match_) != 0) {
            uint8 overdue = elapsed - allowanceOne;
            if (allowanceTwo > overdue) {
                survivorAllowance = allowanceTwo - overdue;
            }
        } else {
            uint8 remainingTwo =
                allowanceTwo > elapsed ? allowanceTwo - elapsed : 0;
            survivorAllowance = remainingTwo;
        }

        return
            _settleMatch(
                state, configId, matchIndex, survivorAllowance, current
            );
    }

    function _prove(
        uint64 state,
        uint16 configId,
        uint8 matchIndex,
        bool highWins
    ) private pure returns (uint64) {
        uint8 current = _current(state);
        uint16 match_ = _matchAt(state, matchIndex);
        assert(_responsesRemaining(match_) == 0);
        assert(!_isTimedOut(match_, current));

        uint8 winningAllowance =
            highWins ? _allowanceTwo(match_) : _allowanceOne(match_);
        uint8 survivorAllowance =
            winningAllowance - (current - _startInstant(match_));
        assert(survivorAllowance != 0);

        return
            _settleMatch(
                state, configId, matchIndex, survivorAllowance, current
            );
    }

    function _settleMatch(
        uint64 state,
        uint16 configId,
        uint8 matchIndex,
        uint8 survivorAllowance,
        uint8 current
    ) private pure returns (uint64) {
        uint8 dangling = _dangling(state);
        state = _removeMatch(state, matchIndex);
        if (survivorAllowance == 0) return state;

        if (dangling == 0) {
            return _setDangling(state, survivorAllowance);
        }

        state = _setDangling(state, 0);
        return _insertMatch(
            state,
            _encodeMatch(
                _configuredHeight(configId),
                dangling,
                survivorAllowance,
                current
            )
        );
    }

    function _applySelectedAction(uint64 state, uint16 configId, uint8 action)
        private
        pure
        returns (uint64)
    {
        ActionKind kind = ActionKind(action >> 2);
        uint8 matchIndex = action & 3;
        if (kind == ActionKind.JOIN) return _join(state, configId);
        if (kind == ActionKind.RESPOND) {
            return _respond(state, configId, matchIndex);
        }
        if (kind == ActionKind.TIMEOUT) {
            return _timeout(state, configId, matchIndex);
        }
        if (kind == ActionKind.PROVE_LOW) {
            return _prove(state, configId, matchIndex, false);
        }
        if (kind == ActionKind.PROVE_HIGH) {
            return _prove(state, configId, matchIndex, true);
        }
        if (kind == ActionKind.WAIT) {
            return _setCurrent(state, _current(state) + 1);
        }
        revert SolverInvariant();
    }

    function _isTimedOut(uint16 match_, uint8 current)
        private
        pure
        returns (bool)
    {
        return current - _startInstant(match_) >= _allowanceOne(match_);
    }

    function _isTerminal(uint64 state, uint8 allowance)
        private
        pure
        returns (bool)
    {
        uint8 unjoined = _unjoined(state);
        if (_current(state) >= allowance && unjoined != 0) {
            revert SolverInvariant();
        }
        return unjoined == 0 && _matchCount(state) == 0;
    }

    function _initialState(uint8 claims) private pure returns (uint64) {
        return uint64(uint256(claims) << UNJOINED_SHIFT);
    }

    function _inspectState(uint64 state)
        private
        pure
        returns (StateView memory view_)
    {
        view_.current = _current(state);
        view_.unjoined = _unjoined(state);
        view_.danglingAllowance = _dangling(state);
        view_.matchCount = _matchCount(state);
    }

    function _inspectMatch(uint16 match_)
        private
        pure
        returns (MatchView memory view_)
    {
        view_.responsesRemaining = _responsesRemaining(match_);
        view_.allowanceOne = _allowanceOne(match_);
        view_.allowanceTwo = _allowanceTwo(match_);
        view_.startInstant = _startInstant(match_);
    }

    function _encodeMatch(
        uint8 responsesRemaining,
        uint8 allowanceOne,
        uint8 allowanceTwo,
        uint8 startInstant
    ) private pure returns (uint16) {
        assert(responsesRemaining <= MAX_HEIGHT);
        assert(allowanceOne != 0 && allowanceOne <= MAX_ALLOWANCE);
        assert(allowanceTwo != 0 && allowanceTwo <= MAX_ALLOWANCE);
        assert(startInstant <= TIME_MASK);
        return uint16(
            uint256(responsesRemaining) | (uint256(allowanceOne) << 2)
                | (uint256(allowanceTwo) << 5) | (uint256(startInstant) << 8)
        );
    }

    function _insertMatch(uint64 state, uint16 inserted)
        private
        pure
        returns (uint64)
    {
        uint8 count = _matchCount(state);
        assert(count < MAX_MATCHES);
        uint256 result = _clearMatches(state, count + 1);
        uint8 source;
        bool consumed;
        for (uint8 target; target < count + 1; ++target) {
            uint16 candidate = source < count ? _matchAt(state, source) : 0;
            if (!consumed && (source == count || inserted < candidate)) {
                result |= uint256(inserted)
                << (MATCHES_SHIFT + target * MATCH_BITS);
                consumed = true;
            } else {
                result |= uint256(candidate)
                << (MATCHES_SHIFT + target * MATCH_BITS);
                ++source;
            }
        }
        // All writes target the 63-bit packed-state layout.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(result);
    }

    function _replaceMatch(uint64 state, uint8 index, uint16 replacement)
        private
        pure
        returns (uint64)
    {
        state = _removeMatch(state, index);
        return _insertMatch(state, replacement);
    }

    function _removeMatch(uint64 state, uint8 removed)
        private
        pure
        returns (uint64)
    {
        uint8 count = _matchCount(state);
        assert(removed < count);
        uint256 result = _clearMatches(state, count - 1);
        uint8 target;
        for (uint8 source; source < count; ++source) {
            if (source == removed) continue;
            result |= uint256(_matchAt(state, source))
            << (MATCHES_SHIFT + target * MATCH_BITS);
            ++target;
        }
        // All writes target the 63-bit packed-state layout.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(result);
    }

    function _clearMatches(uint64 state, uint8 count)
        private
        pure
        returns (uint256 cleared)
    {
        cleared = uint256(state);
        for (uint8 i; i < MAX_MATCHES; ++i) {
            cleared &= ~(MATCH_MASK << (MATCHES_SHIFT + i * MATCH_BITS));
        }
        cleared &= ~(TWO_BIT_MASK << MATCH_COUNT_SHIFT);
        cleared |= uint256(count) << MATCH_COUNT_SHIFT;
    }

    function _matchAt(uint64 state, uint8 index) private pure returns (uint16) {
        uint256 extracted =
            (uint256(state) >> (MATCHES_SHIFT + index * MATCH_BITS))
                & MATCH_MASK;
        // The extracted field is masked to exactly 16 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(extracted);
    }

    function _current(uint64 state) private pure returns (uint8) {
        // The extracted field is masked to seven bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(uint256(state) & TIME_MASK);
    }

    function _unjoined(uint64 state) private pure returns (uint8) {
        // The extracted field is masked to three bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((uint256(state) >> UNJOINED_SHIFT) & THREE_BIT_MASK);
    }

    function _dangling(uint64 state) private pure returns (uint8) {
        // The extracted field is masked to three bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((uint256(state) >> DANGLING_SHIFT) & THREE_BIT_MASK);
    }

    function _matchCount(uint64 state) private pure returns (uint8) {
        // The extracted field is masked to two bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((uint256(state) >> MATCH_COUNT_SHIFT) & TWO_BIT_MASK);
    }

    function _responsesRemaining(uint16 match_) private pure returns (uint8) {
        // The extracted field is masked to two bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(match_ & 3);
    }

    function _allowanceOne(uint16 match_) private pure returns (uint8) {
        return uint8((match_ >> 2) & 7);
    }

    function _allowanceTwo(uint16 match_) private pure returns (uint8) {
        return uint8((match_ >> 5) & 7);
    }

    function _startInstant(uint16 match_) private pure returns (uint8) {
        return uint8((match_ >> 8) & 127);
    }

    function _setCurrent(uint64 state, uint8 current)
        private
        pure
        returns (uint64)
    {
        return uint64((uint256(state) & ~TIME_MASK) | current);
    }

    function _setUnjoined(uint64 state, uint8 unjoined)
        private
        pure
        returns (uint64)
    {
        uint256 mask = THREE_BIT_MASK << UNJOINED_SHIFT;
        return uint64(
            (uint256(state) & ~mask) | (uint256(unjoined) << UNJOINED_SHIFT)
        );
    }

    function _setDangling(uint64 state, uint8 allowance)
        private
        pure
        returns (uint64)
    {
        uint256 mask = THREE_BIT_MASK << DANGLING_SHIFT;
        return uint64(
            (uint256(state) & ~mask) | (uint256(allowance) << DANGLING_SHIFT)
        );
    }

    function _encodeAction(ActionKind kind, uint8 matchIndex)
        private
        pure
        returns (uint8)
    {
        return (uint8(kind) << 2) | matchIndex;
    }

    function _configurationId(Configuration memory config)
        private
        pure
        returns (uint16)
    {
        // The initial claim count is already encoded in the state. Omitting it
        // here lets different population sizes share identical subproblems.
        return uint16(
            (uint16(config.allowance) << 3)
                | (uint16(config.responseBudget) << 6)
                | (uint16(config.height) << 8)
        );
    }

    function _configuredAllowance(uint16 configId)
        private
        pure
        returns (uint8)
    {
        return uint8((configId >> 3) & 7);
    }

    function _configuredResponseBudget(uint16 configId)
        private
        pure
        returns (uint8)
    {
        return uint8((configId >> 6) & 3);
    }

    function _configuredHeight(uint16 configId) private pure returns (uint8) {
        return uint8((configId >> 8) & 3);
    }

    function _key(uint16 configId, uint64 state)
        private
        pure
        returns (uint256)
    {
        return uint256(state) | (uint256(configId) << 64);
    }

    function _decodeCompletion(uint16 stored) private pure returns (uint8) {
        if (stored == 256) return INVALID_COMPLETION;
        // Internal writes store only seven-bit times plus one.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(stored - 1);
    }

    function _memoizedCompletion(uint16 configId, uint64 state)
        private
        view
        returns (uint8)
    {
        uint16 stored = memoizedCompletion[_key(configId, state)];
        if (stored == 0) revert SolverInvariant();
        return _decodeCompletion(stored);
    }

    function _memoize(uint256 key, uint8 completion) private {
        memoizedCompletion[key] =
            completion == INVALID_COMPLETION ? 256 : uint16(completion) + 1;
    }

    function _requireSupported(Configuration memory config) private pure {
        if (
            config.claims == 0 || config.claims > MAX_CLAIMS
                || config.allowance == 0 || config.allowance > MAX_ALLOWANCE
                || config.responseBudget > MAX_RESPONSE_BUDGET
                || config.height == 0 || config.height > MAX_HEIGHT
        ) {
            revert ConfigurationOutsideModelBounds();
        }
    }
}
