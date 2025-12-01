// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ERC1155} from "@openzeppelin-contracts-5.5.0/token/ERC1155/ERC1155.sol";

contract TestMultiToken is ERC1155 {
    constructor() ERC1155("https://test-multi-token.com/{id}.json") {}

    /// @notice Mint multi-tokens for oneself.
    /// @param tokenId The multi-token ID
    /// @param value The amount of fungible tokens to mint
    function mint(uint256 tokenId, uint256 value) external {
        bytes memory data;
        _mint(msg.sender, tokenId, value, data);
    }
}
