// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./tournament/libs/Time.sol";

struct CommitmentStructure {
    uint64 log2step;
    uint64 height;
}

struct TimeConstants {
    Time.Duration matchEffort;
    Time.Duration maxAllowance;
}

struct DisputeParameters {
    TimeConstants timeConstants;
    CommitmentStructure[] commitmentStructures;
}
