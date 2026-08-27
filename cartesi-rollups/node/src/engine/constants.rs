//! Dave-derived values built from the emulator's canonical rollup geometry.
//! The primitive field widths stay owned by `cartesi_machine::constants::rollup`;
//! this module contains only masks and aggregate spans derived from that
//! authority, plus the named checkpoint address used by Dave.

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

#[cfg(test)]
mod tests {
    use super::{CHECKPOINT_ADDRESS, LOG2_EPOCH_RULER_SPAN};
    use cartesi_machine::{
        Machine,
        cartesi_machine_sys::{
            CM_HTIF_CMD_MASK, CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_MASK, CM_HTIF_DEV_SHIFT,
            CM_HTIF_DEV_YIELD, CM_HTIF_REASON_MASK, CM_HTIF_REASON_SHIFT, CM_HTIF_YIELD_CMD_MANUAL,
            CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, CM_REG_HTIF_TOHOST, CM_REG_IFLAGS_Y,
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

    #[test]
    fn machine_validity_proof_geometry_matches_solidity() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let root = manifest_dir.join("../..");
        let emulator_constants = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.9/dependencies/\
             cartesi-machine-solidity-step-0.15.0/src/EmulatorConstants.sol",
        ))
        .expect("read DaveConsensus's vendored EmulatorConstants.sol");
        let memory = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.9/dependencies/\
             cartesi-machine-solidity-step-0.15.0/src/Memory.sol",
        ))
        .expect("read DaveConsensus's vendored Memory.sol");
        let canonical_machine = std::fs::read_to_string(root.join(
            "cartesi-rollups/contracts/dependencies/\
             cartesi-rollups-contracts-3.0.0-alpha.9/src/common/CanonicalMachine.sol",
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

    /// Guardrail: the node's run stride and the emulator's meta-cycle field widths
    /// must match the arbitration contracts and solidity-step. A
    /// drift would make the frontier fold serve level-0 nodes at a
    /// stride the deployed tournament does not use - wrongness with
    /// no loud error, since the fold bypasses the machine-replay
    /// collision checks. (The tournament heights and deeper strides
    /// are read live from chain; the emulator bindings remain static.)
    #[test]
    fn node_geometry_matches_arbitration_contracts() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let root = manifest_dir.join("../..");

        let arbitration = std::fs::read_to_string(
            root.join("prt/contracts/src/arbitration-config/ArbitrationConstants.sol"),
        )
        .expect("read ArbitrationConstants.sol");
        // log2step's array literal: the first element is level 0.
        let log2step_fn = arbitration
            .find("function log2step")
            .expect("log2step in ArbitrationConstants.sol");
        let log2step_0 = first_number_after(&arbitration[log2step_fn..], "[uint64(");
        assert_eq!(
            crate::storage::rollups_machine::LOG2_STRIDE,
            log2step_0,
            "rollups LOG2_STRIDE does not match ArbitrationConstants.log2step(0)"
        );
        let height_fn = arbitration
            .find("function height")
            .expect("height in ArbitrationConstants.sol");
        let height_0 = first_number_after(&arbitration[height_fn..], "[uint64(");
        assert_eq!(
            LOG2_EPOCH_RULER_SPAN,
            log2step_0 + height_0,
            "the ruler span does not match the root tournament's span"
        );

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
