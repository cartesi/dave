// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_machine::{
    Machine,
    config::{
        machine::{MachineConfig, RAMConfig},
        runtime::RuntimeConfig,
    },
};
use rusqlite::Connection;
use tempfile::{TempDir, tempdir};

use super::migrate;

pub fn setup_db() -> (TempDir, Connection) {
    let state_dir_ = tempdir().unwrap();
    let state_dir = state_dir_.path();

    let machine_path = state_dir.join("_my_machine_image");
    let mut machine = Machine::create(
        &MachineConfig::new_with_ram(RAMConfig {
            length: 134217728,
            image_filename: "../../../test/programs/linux.bin".into(),
        }),
        &RuntimeConfig::default(),
    )
    .unwrap();
    machine.store(&machine_path).unwrap();

    let conn = migrate(state_dir, &machine_path, 0).unwrap();
    (state_dir_, conn)
}
