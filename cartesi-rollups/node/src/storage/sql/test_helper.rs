// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::storage::Storage;
use cartesi_machine::{
    Machine,
    cartesi_machine_sys::{
        CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_SHIFT, CM_HTIF_DEV_YIELD, CM_HTIF_REASON_SHIFT,
        CM_HTIF_YIELD_CMD_MANUAL, CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, CM_REG_HTIF_TOHOST,
        CM_REG_IFLAGS_Y,
    },
    config::{
        machine::{MachineConfig, RAMConfig},
        runtime::RuntimeConfig,
    },
};
use tempfile::{TempDir, tempdir};

/// A fully initialized Storage over a real (tiny) machine image: the
/// production setup path, template snapshot and engine config
/// included. Tests need `../../test/programs/linux.bin` present.
pub fn setup_storage() -> (TempDir, Storage) {
    let state_dir_ = tempdir().unwrap();
    let state_dir = state_dir_.path();

    let machine_path = state_dir.join("_my_machine_image");
    let mut machine = Machine::create(
        &MachineConfig::new_with_ram(RAMConfig {
            length: 134217728,
            backing_store: cartesi_machine::config::machine::BackingStoreConfig {
                data_filename: "../../test/programs/linux.bin".into(),
                ..Default::default()
            },
        }),
        &RuntimeConfig::default(),
    )
    .unwrap();
    // Storage tests exercise persistence, not guest execution. Start their
    // template at the canonical awaiting-input boundary required at epoch roll.
    let htif_tohost = (u64::from(CM_HTIF_DEV_YIELD) << CM_HTIF_DEV_SHIFT)
        | (u64::from(CM_HTIF_YIELD_CMD_MANUAL) << CM_HTIF_CMD_SHIFT)
        | (u64::from(CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED) << CM_HTIF_REASON_SHIFT);
    machine.write_reg(CM_REG_IFLAGS_Y, 1).unwrap();
    machine.write_reg(CM_REG_HTIF_TOHOST, htif_tohost).unwrap();
    machine.store(&machine_path).unwrap();

    let storage = Storage::initialize(
        state_dir,
        &machine_path,
        0,
        alloy::primitives::Address::ZERO,
    )
    .unwrap();
    (state_dir_, storage)
}
