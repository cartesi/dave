// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";

/// @dev Selects a post-state from the test payload. This exercises Tournament
/// settlement only; it is not an oracle for state-transition correctness.
contract ProofSelectedStateTransition is IStateTransition {
    error InvalidProofLength(uint256 length);

    function transitionState(
        bytes32,
        uint256,
        bytes calldata proofs,
        IDataProvider
    ) external pure override returns (bytes32) {
        if (proofs.length != 32) {
            revert InvalidProofLength(proofs.length);
        }
        return abi.decode(proofs, (bytes32));
    }
}
