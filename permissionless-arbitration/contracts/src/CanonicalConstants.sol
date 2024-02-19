// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./Time.sol";

library ArbitrationConstants {
    // maximum tolerance time for participant being censored
    // Time.Duration constant CENSORSHIP_TOLERANCE =
    //     Time.Duration.wrap(60 * 60 * 24 * 7);

    // maximum time for computing the commitments offchain
    // Time.Duration constant COMMITMENT_EFFORT =
    //     Time.Duration.wrap(60 * 60 * 4); // TODO

    // maximum time for interacting with a divergence search (match)
    // Time.Duration constant MATCH_EFFORT =
    //     Time.Duration.wrap(60 * 60); // TODO

    Time.Duration constant MAX_ALLOWANCE = Time.Duration.wrap(
        Time.Duration.unwrap(CENSORSHIP_TOLERANCE)
            + Time.Duration.unwrap(COMMITMENT_EFFORT)
    );

    Time.Duration constant COMMITMENT_EFFORT = Time.Duration.wrap(60 * 40);
    Time.Duration constant CENSORSHIP_TOLERANCE = Time.Duration.wrap(60 * 5);
    Time.Duration constant MATCH_EFFORT = Time.Duration.wrap(60 * 2);

    // 3-level tournament
    uint64 constant LEVELS = 4;
    // uint64 constant LOG2_MAX_MCYCLE = 63;

    /// @return log2step gap of each leaf in the tournament[level]
    function log2step(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr =
            [uint64(49), uint64(35), uint64(19), uint64(0)];
        return arr[level];
    }

    /// @return height of the tournament[level] tree which is calculated by subtracting the log2step[level] from the log2step[level - 1]
    function height(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr =
            [uint64(14), uint64(14), uint64(16), uint64(19)];
        return arr[level];
    }
}
