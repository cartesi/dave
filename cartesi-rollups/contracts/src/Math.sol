// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

/// @author Felipe Argento
library Math {
    /// @param a the dividend
    /// @param b the log2 of the divisor
    /// @return ceil(a/2^b)
    function ceilDivExp2(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + (1 << b) - 1) >> b;
    }

    /// @notice get floor of log2 of number
    /// @param x number to take floor(log2) of
    /// @return floor(log2) of x
    function getLog2Floor(uint256 x) internal pure returns (uint8) {
        require(x != 0, "log of zero is undefined");

        return uint8(255 - clz(x));
    }

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

    /// @notice count leading zeros
    /// @param x number you want the clz of
    /// @dev this a binary search implementation
    function clz(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 256;

        uint256 n = 0;
        if (x & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000 == 0) {
            n = n + 128;
            x = x << 128;
        }
        if (x & 0xFFFFFFFFFFFFFFFF000000000000000000000000000000000000000000000000 == 0) {
            n = n + 64;
            x = x << 64;
        }
        if (x & 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 32;
            x = x << 32;
        }
        if (x & 0xFFFF000000000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 16;
            x = x << 16;
        }
        if (x & 0xFF00000000000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 8;
            x = x << 8;
        }
        if (x & 0xF000000000000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 4;
            x = x << 4;
        }
        if (x & 0xC000000000000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 2;
            x = x << 2;
        }
        if (x & 0x8000000000000000000000000000000000000000000000000000000000000000 == 0) {
            n = n + 1;
        }

        return n;
    }
}
