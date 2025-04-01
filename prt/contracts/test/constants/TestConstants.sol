// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/libs/Time.sol";

library TestArbitrationConstants {
    Time.Duration constant COMMITMENT_EFFORT = Time.Duration.wrap(60 * 60);
    Time.Duration constant CENSORSHIP_TOLERANCE = Time.Duration.wrap(60 * 5);
    Time.Duration constant MATCH_EFFORT = Time.Duration.wrap(60 * 2);

    Time.Duration constant MAX_ALLOWANCE = Time.Duration.wrap(
        Time.Duration.unwrap(CENSORSHIP_TOLERANCE)
            + Time.Duration.unwrap(COMMITMENT_EFFORT)
    );

    // 3-level tournament
    uint64 constant LEVELS = 3;

    /// @return log2step gap of each leaf in the tournament[level]
    function log2step(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(44), uint64(27), uint64(0)];
        return arr[level];
    }

    /// @return height of the tournament[level] tree which is calculated by subtracting the log2step[level] from the log2step[level - 1]
    function height(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(48), uint64(17), uint64(27)];
        return arr[level];
    }
}
