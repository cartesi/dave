// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library Time {
    type Instant is uint64;
    type Duration is uint64;

    using Time for Instant;
    using Time for Duration;

    Instant constant ZERO_INSTANT = Instant.wrap(0);
    Duration constant ZERO_DURATION = Duration.wrap(0);

    // Rename as currentInstant?
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

    // Rename as gtInstant?
    //
    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Time.gtInstant as >} for Time.Instant;
    function gt(Instant left, Instant right) internal pure returns (bool) {
        uint64 l = Instant.unwrap(left);
        uint64 r = Instant.unwrap(right);
        return l > r;
    }

    // Rename as gtDuration?
    //
    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Time.gtDuration as >} for Time.Duration;
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

    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Time.add as +} for Time.Duration;
    function add(Duration left, Duration right)
        internal
        pure
        returns (Duration)
    {
        uint64 l = Duration.unwrap(left);
        uint64 r = Duration.unwrap(right);
        return Duration.wrap(l + r);
    }

    // Rename as subDuration?
    //
    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Time.subDuration as -} for Time.Duration;
    function sub(Duration left, Duration right)
        internal
        pure
        returns (Duration)
    {
        uint64 l = Duration.unwrap(left);
        uint64 r = Duration.unwrap(right);
        return Duration.wrap(l - r);
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

    // Rename as subInstant?
    // When we talk about the time span between
    // events E1 and E2, usually E1 happens before E2.
    // But, in this function, E1 happens after E2.
    // The name `subInstant` would obviate the order of operands.
    // Alternatively, we can keep the name but flip the operands
    // in the implementation of the function.
    //
    // If we use the name `subInstant`, then
    // contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Time.subInstant as -} for Time.Instant;
    function timeSpan(Instant left, Instant right)
        internal
        pure
        returns (Duration)
    {
        uint64 l = Instant.unwrap(left);
        uint64 r = Instant.unwrap(right);
        return Duration.wrap(l - r);
    }

    // This function and timeoutElapsed are confusing.
    // I think it would be easier to understand if we, instead,
    // just added the timestamp and the duration
    // and checked whether the result is greater than
    // the current timestamp or not, explicitly.
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

    function min(Duration left, Duration right)
        internal
        pure
        returns (Duration)
    {
        return left.gt(right) ? right : left;
    }
}
