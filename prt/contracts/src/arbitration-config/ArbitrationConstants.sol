// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library ArbitrationConstants {
    // 3-level tournament
    uint64 constant LEVELS = 3;

    /// @return base-2 stride between adjacent commitment leaves at `level`
    function log2step(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(44), uint64(27), uint64(0)];
        return arr[level];
    }

    /// @notice For `level > 0`, the height is the stride gap from
    /// `log2step(level - 1)` to `log2step(level)`. Level-zero height is
    /// dimensioned independently; `height(0) + log2step(0) = 92` spans the
    /// meta-cycle coordinate space.
    /// @return configured commitment-tree height for `level`
    function height(uint64 level) internal pure returns (uint64) {
        uint64[LEVELS] memory arr = [uint64(48), uint64(17), uint64(27)];
        return arr[level];
    }
}
