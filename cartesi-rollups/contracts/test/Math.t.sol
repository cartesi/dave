// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Math} from "src/Math.sol";

library NaiveMath {
    function ctz(uint256 x) internal pure returns (uint256) {
        uint256 n = 256;
        while (x != 0) {
            --n;
            x <<= 1;
        }
        return n;
    }

    function clz(uint256 x) internal pure returns (uint256) {
        uint256 n = 256;
        while (x != 0) {
            --n;
            x >>= 1;
        }
        return n;
    }

    function log2clp(uint256 x) internal pure returns (uint256) {
        for (uint256 i; i < 256; ++i) {
            if (x <= (1 << i)) {
                return i;
            }
        }
        return 256;
    }
}

contract MathTest is Test {
    function testCtz() external pure {
        assertEq(Math.ctz(0), 256);
        assertEq(Math.ctz(type(uint256).max), 0);
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.ctz(1 << i), i);
            for (uint256 j = i + 1; j < 256; ++j) {
                assertEq(Math.ctz((1 << i) | (1 << j)), i);
            }
        }
    }

    function testCtz(uint256 x) external pure {
        assertEq(Math.ctz(x), NaiveMath.ctz(x));
    }

    function testClz() external pure {
        assertEq(Math.clz(0), 256);
        assertEq(Math.clz(type(uint256).max), 0);
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.clz(1 << i), 255 - i);
            for (uint256 j; j < i; ++j) {
                assertEq(Math.clz((1 << i) | (1 << j)), 255 - i);
            }
        }
    }

    function testClz(uint256 x) external pure {
        assertEq(Math.clz(x), NaiveMath.clz(x));
    }

    function testLog2Clp() external pure {
        assertEq(Math.log2clp(0), 0);
        assertEq(Math.log2clp(type(uint256).max), 256);
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.log2clp(1 << i), i);
            for (uint256 j; j < i; ++j) {
                assertEq(Math.log2clp((1 << i) | (1 << j)), i + 1);
            }
        }
    }

    function testLog2Clp(uint256 x) external pure {
        assertEq(Math.log2clp(x), NaiveMath.log2clp(x));
    }
}
