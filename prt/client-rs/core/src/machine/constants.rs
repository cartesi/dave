use cartesi_dave_arithmetic as arithmetic;

// log2 value of the maximal number of micro instructions that emulates a big instruction
pub const LOG2_UARCH_SPAN_TO_BARCH: u64 = 20;
pub const UARCH_SPAN_TO_BARCH: u64 = arithmetic::max_uint(LOG2_UARCH_SPAN_TO_BARCH);

// log2 value of the maximal number of big instructions that executes an input
pub const LOG2_BARCH_SPAN_TO_INPUT: u64 = 48;
pub const BARCH_SPAN_TO_INPUT: u64 = arithmetic::max_uint(LOG2_BARCH_SPAN_TO_INPUT);

// log2 value of the maximal number of inputs that allowed in an epoch
pub const LOG2_INPUT_SPAN_TO_EPOCH: u64 = 24;
pub const INPUT_SPAN_TO_EPOCH: u64 = arithmetic::max_uint(LOG2_INPUT_SPAN_TO_EPOCH);

// log2 value of the maximal number of micro instructions that executes an input
pub const LOG2_UARCH_SPAN_TO_INPUT: u64 = LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH;

/// Re-export of the emulator's dedicated memory slot for the pre-input root
/// hash (a.k.a. `CM_AR_SHADOW_REVERT_ROOT_HASH_START`, currently `0xfe0`).
///
/// The off-chain client writes the current root hash to this address before
/// sending a CMIO input, so that on-chain `revertIfNeeded` can read it back
/// and restore the state after a rejected input. The Solidity side mirrors
/// the emulator through step's auto-generated
/// `EmulatorConstants.REVERT_ROOT_HASH_ADDRESS`;
/// `tests::test_emulator_and_step_agree_on_revert_address` asserts the two
/// stay in sync after any emulator or step bump.
pub use cartesi_machine::constants::ar::SHADOW_REVERT_ROOT_HASH_START as CHECKPOINT_ADDRESS;

#[cfg(test)]
mod tests {
    use super::CHECKPOINT_ADDRESS;

    /// Guardrail: step's `EmulatorConstants.sol` is auto-generated from the
    /// emulator C++ source, and `REVERT_ROOT_HASH_ADDRESS` must equal the
    /// emulator's `CM_AR_SHADOW_REVERT_ROOT_HASH_START` — otherwise the
    /// off-chain client writes to one address while on-chain
    /// `revertIfNeeded` reads from another, and any rejected-input dispute
    /// mis-restores state. If this test fails after an emulator or step
    /// bump, the step submodule is out of sync with the emulator version
    /// these bindings link against: regenerate step's `EmulatorConstants.sol`
    /// against the matching emulator and bump both submodule pointers
    /// together.
    #[test]
    fn test_emulator_and_step_agree_on_revert_address() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let emulator_constants_sol = manifest_dir
            .join("../../..")
            .join("machine/step/src/EmulatorConstants.sol");
        let source = std::fs::read_to_string(&emulator_constants_sol)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", emulator_constants_sol.display()));

        // Find: `uint64 constant REVERT_ROOT_HASH_ADDRESS = 0x<hex>;`
        let marker = "REVERT_ROOT_HASH_ADDRESS";
        let pos = source.find(marker).unwrap_or_else(|| {
            panic!("{marker} not found in {}", emulator_constants_sol.display())
        });
        let after = &source[pos + marker.len()..];
        let eq = after.find('=').expect("expected `=` after constant name");
        let semi = after.find(';').expect("expected `;` after constant value");
        let value_str = after[eq + 1..semi].trim();
        let step_value = if let Some(hex) = value_str.strip_prefix("0x") {
            u64::from_str_radix(hex, 16).expect("REVERT_ROOT_HASH_ADDRESS not valid hex")
        } else {
            value_str
                .parse::<u64>()
                .expect("REVERT_ROOT_HASH_ADDRESS not valid decimal")
        };

        assert_eq!(
            CHECKPOINT_ADDRESS, step_value,
            "Emulator CM_AR_SHADOW_REVERT_ROOT_HASH_START ({CHECKPOINT_ADDRESS:#x}) \
             does not match step's EmulatorConstants.REVERT_ROOT_HASH_ADDRESS ({step_value:#x}). \
             The off-chain client and on-chain verifier will disagree on the revert slot."
        );
    }
}
