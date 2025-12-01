// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ERC721} from "@openzeppelin-contracts-5.5.0/token/ERC721/ERC721.sol";

contract TestNonFungibleToken is ERC721 {
    constructor() ERC721("Non-fungible", "NFT") {}

    /// @notice Mint a non-fungible token for oneself.
    /// @param tokenId The non-fungible token ID
    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }
}
