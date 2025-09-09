pragma solidity ^0.8.18;

import "prt-contracts/IStateTransition.sol";
import "risc0/IRiscZeroVerifier.sol";
// Import RISC Zero contracts so they get compiled by Foundry
import "risc0/groth16/RiscZeroGroth16Verifier.sol";
import "risc0/RiscZeroVerifierRouter.sol";

/// @title CartesiStateTransitionWithRiscZero
/// @notice State transition using RISC Zero zkVM proofs, similar to CartesiStateTransition
/// @dev This contract replaces CartesiStateTransition for zkVM-based execution
contract CartesiStateTransitionWithRiscZero is IStateTransition {
    IRiscZeroVerifier public immutable riscZeroVerifier;
    bytes32 public immutable imageId;

    constructor(
        address verifierAddress,
        bytes32 _imageId
    ) {
        riscZeroVerifier = IRiscZeroVerifier(verifierAddress);
        imageId = _imageId;
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
            return transitionRollups(machineState, counter, proofs, provider);
        }
    }

    function transitionCompute(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs
    ) internal view returns (bytes32 newMachineState) {
        // Decode the zkVM proof
        (bytes memory seal, bytes memory journal) = abi.decode(proofs, (bytes, bytes));
        
        // The journal contains the RISC Zero Journal struct:
        // - root_hash_before (bytes32)
        // - mcycle_count (uint64) 
        // - root_hash_after (bytes32)
        (bytes32 rootHashBefore, uint64 mcycleCount, bytes32 rootHashAfter) = 
            abi.decode(journal, (bytes32, uint64, bytes32));
        
        // Verify the input parameters match
        require(rootHashBefore == machineState, "Input state mismatch");
        require(mcycleCount == uint64(counter), "Counter mismatch");
        
        // Compute journal digest for verification
        bytes32 journalDigest = sha256(journal);
        
        // Verify the zkVM proof
        riscZeroVerifier.verify(seal, imageId, journalDigest);
        
        // Return the new state from the verified proof
        newMachineState = rootHashAfter;
    }

    function transitionRollups(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) internal pure returns (bytes32) {
        // Rollup transitions not implemented for RISC Zero
        revert("Rollup transitions not implemented");
    }
}
