// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library ArbitrationConstants {
    uint64 constant LEVELS = 2;

    /// @notice Wall-clock seconds granted to build one inner tournament's
    /// commitment, the same at every inner level. The table is the 60-minute
    /// derivation in docs/measurements/constants.md (the node's bulk leaf
    /// path, hardware slack 2), deployed with 120 minutes for double slack.
    /// A table is only valid for a budget at least the one it was derived at.
    uint64 constant COMMITMENT_BUDGET = 120 minutes;

    /// @return base-2 stride between adjacent commitment leaves at `level`
    function log2step(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(38), uint64(0)];
        return arr[level];
    }

    /// @notice For `level > 0`, the height is the stride gap from
    /// `log2step(level - 1)` to `log2step(level)`. Level-zero height is
    /// dimensioned independently; `height(0) + log2step(0) = 92` spans the
    /// meta-cycle coordinate space.
    /// @return configured commitment-tree height for `level`
    function height(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(54), uint64(38)];
        return arr[level];
    }
}
