// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ERC20} from "@openzeppelin-contracts-5.5.0/token/ERC20/ERC20.sol";

contract TestFungibleToken is ERC20 {
    constructor() ERC20("Fungible", "FUN") {}

    /// @notice Mint fungible tokens for oneself.
    /// @param value The amount of fungible tokens to mint
    function mint(uint256 value) external {
        _mint(msg.sender, value);
    }
}
