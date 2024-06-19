// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "rollups-contracts/inputs/InputBox.sol";

contract Counter {
    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
}
