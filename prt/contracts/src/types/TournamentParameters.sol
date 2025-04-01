// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/libs/Time.sol";

struct TournamentParameters {
    uint64 levels;
    uint64 log2step;
    uint64 height;
    Time.Duration matchEffort;
    Time.Duration maxAllowance;
}
