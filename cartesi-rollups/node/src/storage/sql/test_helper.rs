// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::storage::Storage;
use cartesi_machine::{
    Machine,
    config::{
        machine::{MachineConfig, RAMConfig},
        runtime::RuntimeConfig,
    },
};
use tempfile::{TempDir, tempdir};

/// A fully migrated Storage over a real (tiny) machine image: the
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
    machine.store(&machine_path).unwrap();

    let storage = Storage::migrate(
        state_dir,
        &machine_path,
        0,
        alloy::primitives::Address::ZERO,
    )
    .unwrap();
    (state_dir_, storage)
}
