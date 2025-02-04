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
        else return 256 - clz(~x & (x - 1));
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

    /// @notice the smallest y for which x <= 2^y
    /// @param x number you want the log2clp of
    /// @dev this a binary search implementation
    function log2clp(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        else return 256 - clz(x - 1);
    }

    /// @notice the largest of two numbers
    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x > y) ? x : y;
    }
}
