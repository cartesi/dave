// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Time} from "prt-contracts/tournament/libs/Time.sol";

library ArbitrationConstants {
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
