// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./tournament/libs/Time.sol";

interface ITournamentParameters {
    function levels() external view returns (uint64);
    function log2step(uint256 level) external view returns (uint64);
    function height(uint256 level) external view returns (uint64);
    function matchEffort() external view returns (Time.Duration);
    function maxAllowance() external view returns (Time.Duration);
}
