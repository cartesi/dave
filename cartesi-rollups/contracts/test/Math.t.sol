// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Math} from "src/Math.sol";

library NaiveMath {
    function ctz(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 256;
        uint256 n;
        while (x & 1 == 0) {
            ++n;
            x >>= 1;
        }
        return n;
    }

    function clz(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 256;
        uint256 n;
        while (x & 0x8000000000000000000000000000000000000000000000000000000000000000 == 0) {
            ++n;
            x <<= 1;
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
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.ctz(1 << i), i);
        }
    }

    function testCtz(uint256 x) external pure {
        assertEq(Math.ctz(x), NaiveMath.ctz(x));
    }

    function testClz() external pure {
        assertEq(Math.clz(0), 256);
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.clz(1 << i), 255 - i);
        }
    }

    function testClz(uint256 x) external pure {
        assertEq(Math.clz(x), NaiveMath.clz(x));
    }

    function testLog2Clp() external pure {
        assertEq(Math.log2clp(0), 0);
        for (uint256 i; i < 256; ++i) {
            assertEq(Math.log2clp(1 << i), i);
        }
    }

    function testLog2Clp(uint256 x) external pure {
        assertEq(Math.log2clp(x), NaiveMath.log2clp(x));
    }
}
