// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/types/Machine.sol";
import "prt-contracts/types/Tree.sol";

interface ITournament {
    function arbitrationResult()
        external
        view
        returns (
            bool finished,
            Tree.Node winnerCommitment,
            Machine.Hash finalState
        );
}
