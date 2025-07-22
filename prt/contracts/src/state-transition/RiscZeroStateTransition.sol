pragma solidity ^0.8.18;

import "prt-contracts/IStateTransition.sol";

interface IRiscZeroVerifier {
    function verify(
        bytes calldata seal,
        bytes32 imageId,
        bytes32 journalDigest
    ) external view;
}

contract CartesiStateTransitionWithRiscZero is IStateTransition {
    IRiscZeroVerifier public riscZeroVerifier;
    bytes32 public imageId;

    constructor(
        address verifierAddress,
        bytes32 imId
    ) {
        riscZeroVerifier = IRiscZeroVerifier(verifierAddress);
        imageId = imId;
    }

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32) {
        if (address(provider) == address(0)) {
            return transitionCompute(machineState, counter, proofs);
        } else {
            revert("Rollup transitions not supported in this contract");
        }
    }

    // proof contains a seal and a journal
    function transitionCompute(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proof
    ) internal view returns (bytes32) {
        (bytes memory seal, bytes memory journal) = abi.decode(proof, (bytes, bytes));
        bytes32 journalDigest = sha256(journal);

        riscZeroVerifier.verify(seal, imageId, journalDigest);

        // if we reach here, the proof is valid and the state transition is verified
        return journalDigest;
    }
}
