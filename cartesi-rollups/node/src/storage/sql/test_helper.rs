// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::engine::{EngineConfig, TournamentGeometry};
use crate::storage::{Seed, Storage, Template};
use cartesi_machine::{
    Machine,
    cartesi_machine_sys::{
        CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_SHIFT, CM_HTIF_DEV_YIELD, CM_HTIF_REASON_SHIFT,
        CM_HTIF_YIELD_CMD_MANUAL, CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        CM_HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION, CM_REG_HTIF_TOHOST, CM_REG_IFLAGS_Y,
    },
    config::{
        machine::{MachineConfig, RAMConfig},
        runtime::RuntimeConfig,
    },
};
use std::path::{Path, PathBuf};
use tempfile::{TempDir, tempdir};

/// A fully initialized Storage over a real (tiny) machine image: the
/// production setup path, template snapshot and engine config
/// included, pinned to the two-level table. Tests need
/// `../../test/programs/linux.bin` present.
pub fn setup_storage() -> (TempDir, Storage) {
    setup_storage_with(&TournamentGeometry::two_level())
}

/// [`setup_storage`] pinned to `geometry`.
pub fn setup_storage_with(geometry: &TournamentGeometry) -> (TempDir, Storage) {
    let state_dir_ = tempdir().unwrap();
    let state_dir = state_dir_.path();

    let machine_path = state_dir.join("_my_machine_image");
    store_template(&machine_path, |_| {});

    let storage = seed_storage(state_dir, &machine_path, 0, geometry);
    (state_dir_, storage)
}

/// Initializes `state_dir`, seeded at `epoch` from the image at `image`
/// with watermark 0, for app, consensus and chain zero, pinned to
/// `geometry`. The image stands for the deployment's initial state, as a
/// template does.
pub fn seed_storage(
    state_dir: &Path,
    image: &Path,
    epoch: u64,
    geometry: &TournamentGeometry,
) -> Storage {
    let image = Template::inspect(image).unwrap();
    let config = EngineConfig::for_deployment(
        0,
        alloy::primitives::Address::ZERO,
        alloy::primitives::Address::ZERO,
        *image.hash(),
        geometry.clone(),
    );
    let seed = Seed {
        image,
        epoch,
        watermark: 0,
    };
    Storage::initialize(state_dir, Some(&seed), &config).unwrap()
}

/// A stand-in published snapshot for `hash`: an empty directory at its
/// store path, enough for rows a test never loads.
pub fn stub_snapshot(storage: &Storage, hash: &cartesi_machine::types::Hash) -> PathBuf {
    let path = crate::storage::snapshots::snapshot_path(storage.state_dir(), hash);
    std::fs::create_dir_all(&path).unwrap();
    path
}

/// Presets a manual exception yield: the ordinary terminal state, from
/// which no epoch can start.
pub fn yield_exception(machine: &mut Machine) {
    let htif_tohost = (u64::from(CM_HTIF_DEV_YIELD) << CM_HTIF_DEV_SHIFT)
        | (u64::from(CM_HTIF_YIELD_CMD_MANUAL) << CM_HTIF_CMD_SHIFT)
        | (u64::from(CM_HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION) << CM_HTIF_REASON_SHIFT);
    machine.write_reg(CM_REG_HTIF_TOHOST, htif_tohost).unwrap();
}

/// Stores the tiny template at `path`, after `adjust` edits the machine.
pub fn store_template(path: &Path, adjust: impl FnOnce(&mut Machine)) {
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
    adjust(&mut machine);
    machine.store(path).unwrap();
}
