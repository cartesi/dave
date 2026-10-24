// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";

/// @notice A private CREATE2 namespace for one DaveAppFactory.
/// @dev The trusted ApplicationFactory implementation is stateless; delegation
/// retains its immutable refund builder while deploying from this address.
contract PrivateApplicationFactory {
    address immutable OWNER = msg.sender;
    address immutable IMPLEMENTATION;

    error UnauthorizedCaller();

    constructor(IApplicationFactory implementation) {
        IMPLEMENTATION = address(implementation);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == OWNER, UnauthorizedCaller());
        (bool success, bytes memory result) = IMPLEMENTATION.delegatecall(data);
        if (!success) {
            // Preserve empty CREATE2-collision reverts; functionDelegateCall
            // would replace them with FailedCall().
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}
