// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

/// @notice Block-number time types and arithmetic for tournament deadlines.
/// @dev Instants use `uint64(block.number)`, not `block.timestamp`. Clock storage
/// uses the zero instant as its paused marker.
library Time {
    type Instant is uint64;
    type Duration is uint64;

    using Time for Instant;
    using Time for Duration;

    Instant constant ZERO_INSTANT = Instant.wrap(0);
    Duration constant ZERO_DURATION = Duration.wrap(0);

    /// @notice Return the current EVM block-number coordinate.
    /// @dev Deployment policy converts wall-clock durations into this coordinate.
    function currentTime() internal view returns (Instant) {
        return Instant.wrap(uint64(block.number));
    }

    function add(Instant timestamp, Duration duration)
        internal
        pure
        returns (Instant)
    {
        uint64 t = Instant.unwrap(timestamp);
        uint64 d = Duration.unwrap(duration);
        return Instant.wrap(t + d);
    }

    function gt(Instant left, Instant right) internal pure returns (bool) {
        uint64 l = Instant.unwrap(left);
        uint64 r = Instant.unwrap(right);
        return l > r;
    }

    function gt(Duration left, Duration right) internal pure returns (bool) {
        uint64 l = Duration.unwrap(left);
        uint64 r = Duration.unwrap(right);
        return l > r;
    }

    function isZero(Instant timestamp) internal pure returns (bool) {
        uint64 t = Instant.unwrap(timestamp);
        return t == 0;
    }

    function isZero(Duration duration) internal pure returns (bool) {
        uint64 d = Duration.unwrap(duration);
        return d == 0;
    }

    function monus(Duration left, Duration right)
        internal
        pure
        returns (Duration)
    {
        uint64 l = Duration.unwrap(left);
        uint64 r = Duration.unwrap(right);
        return Duration.wrap(l < r ? 0 : l - r);
    }

    /// @notice Return the duration from `right` to `left`.
    /// @dev Requires `left >= right`; checked arithmetic reverts otherwise.
    function timeSpan(Instant left, Instant right)
        internal
        pure
        returns (Duration)
    {
        uint64 l = Instant.unwrap(left);
        uint64 r = Instant.unwrap(right);
        return Duration.wrap(l - r);
    }

    /// @notice Return whether `current` has reached the deadline.
    /// @dev Expiry is inclusive: equality with `timestamp + duration` is timed out.
    function timeoutElapsedSince(
        Instant timestamp,
        Duration duration,
        Instant current
    ) internal pure returns (bool) {
        return !timestamp.add(duration).gt(current);
    }

    function timeoutElapsed(Instant timestamp, Duration duration)
        internal
        view
        returns (bool)
    {
        return timestamp.timeoutElapsedSince(duration, currentTime());
    }

    function max(Duration left, Duration right)
        internal
        pure
        returns (Duration)
    {
        return left.gt(right) ? left : right;
    }

    function max(Instant left, Instant right) internal pure returns (Instant) {
        return left.gt(right) ? left : right;
    }
}
