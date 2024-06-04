// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "src/Machine.sol";
import "src/Tree.sol";

interface ITournament {
    function arbitrationResult()
        external
        view
        returns (bool, Tree.Node, Machine.Hash);
}
