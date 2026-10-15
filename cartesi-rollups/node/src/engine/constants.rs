//! Dave-derived values built from the emulator's canonical rollup geometry.
//! The primitive field widths stay owned by `cartesi_machine::constants::rollup`;
//! this module contains only masks and aggregate spans derived from that
//! authority, plus the named checkpoint address and the uarch state's node
//! used by Dave.

use crate::arithmetic;
use cartesi_machine::constants::rollup::{
    LOG2_MAX_ADVANCE_STATES_PER_EPOCH, LOG2_MAX_MCYCLES_PER_ADVANCE_STATE,
    LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
};

pub const UARCH_MASK_TO_BARCH: u64 = arithmetic::max_uint(LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);

pub const BARCH_MASK_TO_INPUT: u64 = arithmetic::max_uint(LOG2_MAX_MCYCLES_PER_ADVANCE_STATE);

pub const INPUT_MASK_TO_EPOCH: u64 = arithmetic::max_uint(LOG2_MAX_ADVANCE_STATES_PER_EPOCH);

/// Meta-cycles in one input window: log2.
pub const LOG2_INPUT_WINDOW_SPAN: u64 =
    LOG2_MAX_MCYCLES_PER_ADVANCE_STATE + LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;

/// Meta-cycles in one epoch ruler: log2.
pub const LOG2_EPOCH_RULER_SPAN: u64 = LOG2_MAX_ADVANCE_STATES_PER_EPOCH + LOG2_INPUT_WINDOW_SPAN;

/// Re-export of the emulator's dedicated memory slot for the pre-input root
/// hash (a.k.a. `CM_AR_SHADOW_REVERT_ROOT_HASH_START`, currently `0xfe0`).
///
/// The emulator's send-CMIO primitive records the supplied pre-input root at
/// this address, and the reset primitive substitutes it after a rejected
/// input. The Solidity side mirrors the emulator through step's auto-generated
/// `EmulatorConstants.REVERT_ROOT_HASH_ADDRESS`;
/// `tests::test_emulator_and_step_agree_on_revert_address` asserts the two
/// stay in sync after any emulator or step bump.
pub use cartesi_machine::constants::ar::SHADOW_REVERT_ROOT_HASH_START as CHECKPOINT_ADDRESS;

/// The uarch state's node in the machine hash tree, which every uarch reset
/// rewrites whole (solidity-step's `EmulatorCompat.resetState`), to the hash
/// `Machine::uarch_pristine_hash` returns.
/// `tests::linked_emulator_and_step_agree_on_the_pristine_uarch` holds the C
/// API's values to step's `UARCH_STATE_START_ADDRESS` and
/// `UARCH_STATE_LOG2_SIZE`.
pub use cartesi_machine::constants::ar::{UARCH_STATE_LOG2_SIZE, UARCH_STATE_START};

#[cfg(test)]
mod tests {
    use super::{CHECKPOINT_ADDRESS, UARCH_STATE_LOG2_SIZE, UARCH_STATE_START};
    use alloy::primitives::B256;
    use cartesi_machine::{
        Machine,
        cartesi_machine_sys::{
            CM_HTIF_CMD_MASK, CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_MASK, CM_HTIF_DEV_SHIFT,
            CM_HTIF_DEV_YIELD, CM_HTIF_REASON_MASK, CM_HTIF_REASON_SHIFT, CM_HTIF_YIELD_CMD_MANUAL,
            CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, CM_MARCHID, CM_REG_HTIF_TOHOST,
            CM_REG_IFLAGS_Y,
        },
        constants::{
            ar::TX_START,
            machine::{HASH_TREE_LOG2_ROOT_SIZE, HASH_TREE_LOG2_WORD_SIZE},
            rollup::{
                LOG2_MAX_ADVANCE_STATES_PER_EPOCH, LOG2_MAX_MCYCLES_PER_ADVANCE_STATE,
                LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
            },
        },
    };

    fn solidity_constant(source: &str, marker: &str) -> u64 {
        let pos = source
            .find(marker)
            .unwrap_or_else(|| panic!("{marker} not found in contract source"));
        let after = &source[pos + marker.len()..];
        let eq = after.find('=').expect("expected `=` after constant name");
        let semi = after.find(';').expect("expected `;` after constant value");
        let value = after[eq + 1..semi].trim();
        value
            .strip_prefix("0x")
            .map(|hex| u64::from_str_radix(hex, 16))
            .unwrap_or_else(|| value.parse())
            .unwrap_or_else(|_| panic!("{marker} is not a numeric Solidity constant"))
    }

    /// Guardrail: step's `EmulatorConstants.sol` is auto-generated from the
    /// emulator C++ source, and `REVERT_ROOT_HASH_ADDRESS` must equal the
    /// emulator's `CM_AR_SHADOW_REVERT_ROOT_HASH_START` - otherwise the
    /// emulator send primitive records one leaf while the on-chain reset
    /// reads another, and any rejected-input dispute mis-restores state.
    /// If this test fails after an emulator or step
    /// bump, the step submodule is out of sync with the emulator version
    /// these bindings link against: regenerate step's `EmulatorConstants.sol`
    /// against the matching emulator and bump both submodule pointers
    /// together.
    #[test]
    fn test_emulator_and_step_agree_on_revert_address() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let emulator_constants_sol = manifest_dir
            .join("../..")
            .join("machine/step/src/EmulatorConstants.sol");
        let source = std::fs::read_to_string(&emulator_constants_sol)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", emulator_constants_sol.display()));

        let step_value = solidity_constant(&source, "REVERT_ROOT_HASH_ADDRESS");

        assert_eq!(
            CHECKPOINT_ADDRESS, step_value,
            "Emulator CM_AR_SHADOW_REVERT_ROOT_HASH_START ({CHECKPOINT_ADDRESS:#x}) \
             does not match step's EmulatorConstants.REVERT_ROOT_HASH_ADDRESS ({step_value:#x}). \
             The off-chain client and on-chain verifier will disagree on the revert slot."
        );
    }

    fn solidity_bytes32(source: &str, marker: &str) -> B256 {
        let pos = source
            .find(marker)
            .unwrap_or_else(|| panic!("{marker} not found in contract source"));
        let after = &source[pos + marker.len()..];
        let eq = after.find('=').expect("expected `=` after constant name");
        let semi = after.find(';').expect("expected `;` after constant value");
        after[eq + 1..semi]
            .trim()
            .parse()
            .unwrap_or_else(|_| panic!("{marker} is not a bytes32 Solidity constant"))
    }

    /// Guardrail: every uarch reset the on-chain step verifies writes step's
    /// `UARCH_PRISTINE_STATE_HASH` over the uarch region, while every reset
    /// the node runs or logs restores the linked emulator's. Startup refuses
    /// a deployment or a template whose hash or `CM_MARCHID` differs from the
    /// linked emulator's; this holds the step submodule to the same values,
    /// and the C API's uarch coordinates to step's, so a mismatched emulator
    /// or step bump fails here, not at startup. They move only in a
    /// coordinated generation (docs/build-system.md): bump both together.
    #[test]
    fn linked_emulator_and_step_agree_on_the_pristine_uarch() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source = std::fs::read_to_string(
            manifest_dir
                .join("../..")
                .join("machine/step/src/EmulatorConstants.sol"),
        )
        .expect("read EmulatorConstants.sol");

        assert_eq!(
            UARCH_STATE_START,
            solidity_constant(&source, "UARCH_STATE_START_ADDRESS"),
            "uarch state start disagrees with EmulatorConstants.sol"
        );
        assert_eq!(
            u64::from(UARCH_STATE_LOG2_SIZE),
            solidity_constant(&source, "UARCH_STATE_LOG2_SIZE"),
            "uarch state size disagrees with EmulatorConstants.sol"
        );
        assert_eq!(
            u64::from(CM_MARCHID),
            solidity_constant(&source, "CM_MARCHID"),
            "the linked emulator's CM_MARCHID disagrees with EmulatorConstants.sol"
        );
        let linked = B256::from(Machine::uarch_pristine_hash());
        let step = solidity_bytes32(&source, "UARCH_PRISTINE_STATE_HASH");
        assert_eq!(
            linked, step,
            "the linked emulator resets the uarch to {linked}, but step's \
             EmulatorConstants.UARCH_PRISTINE_STATE_HASH is {step}"
        );
    }

    #[test]
    fn machine_validity_proof_geometry_matches_solidity() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let root = manifest_dir.join("../..");
        let emulator_constants = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.10/dependencies/\
             cartesi-machine-solidity-step-0.15.0/src/EmulatorConstants.sol",
        ))
        .expect("read DaveConsensus's vendored EmulatorConstants.sol");
        let memory = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.10/dependencies/\
             cartesi-machine-solidity-step-0.15.0/src/Memory.sol",
        ))
        .expect("read DaveConsensus's vendored Memory.sol");
        let canonical_machine = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.10/src/common/CanonicalMachine.sol",
        ))
        .expect("read CanonicalMachine.sol");

        assert_eq!(
            Machine::reg_address(CM_REG_IFLAGS_Y).unwrap(),
            solidity_constant(&emulator_constants, "IFLAGS_Y_ADDRESS")
        );
        assert_eq!(
            Machine::reg_address(CM_REG_HTIF_TOHOST).unwrap(),
            solidity_constant(&emulator_constants, "HTIF_TOHOST_ADDRESS")
        );
        assert_eq!(
            TX_START,
            solidity_constant(&emulator_constants, "AR_CMIO_TX_BUFFER_START")
        );
        assert_eq!(
            u64::from(HASH_TREE_LOG2_WORD_SIZE),
            solidity_constant(&memory, "uint8 constant LOG2_LEAF")
        );
        assert_eq!(
            u64::from(HASH_TREE_LOG2_ROOT_SIZE),
            solidity_constant(&canonical_machine, "LOG2_MEMORY_SIZE")
        );
        for (marker, emulator_value) in [
            ("HTIF_DEV_MASK", CM_HTIF_DEV_MASK),
            ("HTIF_CMD_MASK", CM_HTIF_CMD_MASK),
            ("HTIF_REASON_MASK", CM_HTIF_REASON_MASK),
            ("HTIF_DEV_SHIFT", u64::from(CM_HTIF_DEV_SHIFT)),
            ("HTIF_CMD_SHIFT", u64::from(CM_HTIF_CMD_SHIFT)),
            ("HTIF_REASON_SHIFT", u64::from(CM_HTIF_REASON_SHIFT)),
            ("HTIF_DEV_YIELD", u64::from(CM_HTIF_DEV_YIELD)),
            ("HTIF_YIELD_CMD_MANUAL", u64::from(CM_HTIF_YIELD_CMD_MANUAL)),
            (
                "HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED",
                u64::from(CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED),
            ),
        ] {
            assert_eq!(
                emulator_value,
                solidity_constant(&emulator_constants, marker),
                "Cartesi Machine and DaveConsensus disagree on {marker}"
            );
        }
    }

    /// The first number appearing after `marker` in `source` (digits
    /// only, delimiters skipped): dumb but loud, like the parser above.
    fn first_number_after(source: &str, marker: &str) -> u64 {
        let pos = source
            .find(marker)
            .unwrap_or_else(|| panic!("{marker} not found in contract source"));
        let after = &source[pos + marker.len()..];
        let start = after
            .find(|c: char| c.is_ascii_digit())
            .expect("no number after marker");
        let digits: String = after[start..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        digits.parse().expect("digits parse as u64")
    }

    /// Guardrail: the checked-in arbitration table must pass the node's
    /// geometry validator (the node discovers the deployed table at
    /// startup and refuses one it cannot run), and the emulator's
    /// meta-cycle field widths must match solidity-step.
    #[test]
    fn node_geometry_matches_arbitration_contracts() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let root = manifest_dir.join("../..");

        // Parsing builds the table through the validator.
        crate::engine::TournamentGeometry::checked_in();

        let transition =
            std::fs::read_to_string(root.join("machine/step/src/EmulatorConstants.sol"))
                .expect("read EmulatorConstants.sol");
        assert_eq!(
            LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
            first_number_after(&transition, "ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE =",),
            "uarch span width disagrees with EmulatorConstants.sol"
        );
        assert_eq!(
            LOG2_MAX_MCYCLES_PER_ADVANCE_STATE,
            first_number_after(&transition, "ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE =",),
            "barch span width disagrees with EmulatorConstants.sol"
        );
        assert_eq!(
            LOG2_MAX_ADVANCE_STATES_PER_EPOCH,
            first_number_after(&transition, "ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH =",),
            "input span width disagrees with EmulatorConstants.sol"
        );
    }
}
