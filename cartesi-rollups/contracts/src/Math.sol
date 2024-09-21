// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

/// @author Felipe Argento
library Math {
    /// @notice count trailing zeros
    /// @param x number you want the ctz of
    /// @dev this a binary search implementation
    function ctz(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 256;

        uint256 n = 0;
        if (x & 0x00000000000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF == 0) {
            n = n + 128;
            x = x >> 128;
        }
        if (x & 0x000000000000000000000000000000000000000000000000FFFFFFFFFFFFFFFF == 0) {
            n = n + 64;
            x = x >> 64;
        }
        if (x & 0x00000000000000000000000000000000000000000000000000000000FFFFFFFF == 0) {
            n = n + 32;
            x = x >> 32;
        }
        if (x & 0x000000000000000000000000000000000000000000000000000000000000FFFF == 0) {
            n = n + 16;
            x = x >> 16;
        }
        if (x & 0x00000000000000000000000000000000000000000000000000000000000000FF == 0) {
            n = n + 8;
            x = x >> 8;
        }
        if (x & 0x000000000000000000000000000000000000000000000000000000000000000F == 0) {
            n = n + 4;
            x = x >> 4;
        }
        if (x & 0x0000000000000000000000000000000000000000000000000000000000000003 == 0) {
            n = n + 2;
            x = x >> 2;
        }
        if (x & 0x0000000000000000000000000000000000000000000000000000000000000001 == 0) {
            n = n + 1;
        }

        return n;
    }
}
