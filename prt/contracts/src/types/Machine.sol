// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

library Machine {
    type Hash is bytes32;

    // Rename to ZERO_HASH or ZERO_STATE_HASH?
    Hash constant ZERO_STATE = Hash.wrap(0x0);

    // Rename to isZero or isZeroHash?
    function notInitialized(Hash hash) internal pure returns (bool) {
        // It could use the `eq` function defined in this library
        // to compare `hash` with the ZERO_HASH constant.
        bytes32 h = Hash.unwrap(hash);
        return h == 0x0;
    }

    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Machine.eq as ==} for Machine.Hash;
    function eq(Hash left, Hash right) internal pure returns (bool) {
        bytes32 l = Hash.unwrap(left);
        bytes32 r = Hash.unwrap(right);
        return l == r;
    }

    type Cycle is uint256; // TODO overcomplicated?
    type Log2Step is uint64; // TODO overcomplicated?
}
