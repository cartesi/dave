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

use super::{migrations, set_scalar_function};

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

    let mut conn = Connection::open_in_memory().unwrap();
    conn.busy_timeout(std::time::Duration::from_secs(10))
        .map_err(anyhow::Error::from)
        .unwrap();
    set_scalar_function(&conn).unwrap();
    migrations::migrate_to_latest(&mut conn).unwrap();

    (state_dir_, conn)
}
