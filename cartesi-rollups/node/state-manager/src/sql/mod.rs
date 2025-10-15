// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod consensus_data;
pub mod migrations;
pub mod rollup_data;

#[cfg(test)]
pub(crate) mod test_helper;

use crate::{rollups_machine::RollupsMachine, state_manager::Result};
use anyhow::Context;
use rusqlite::{Connection, functions::FunctionFlags};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub fn fs_delete_dir(
    ctx: &rusqlite::functions::Context,
) -> std::result::Result<rusqlite::types::Null, rusqlite::Error> {
    let path: String = ctx.get(0)?;
    std::fs::remove_dir_all(&path).map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))?;
    Ok(rusqlite::types::Null)
}

fn set_genesis(connection: &Connection, block_number: u64) -> Result<()> {
    let last_processed = consensus_data::last_processed_block(connection)?;

    if block_number > last_processed {
        consensus_data::update_last_processed_block(connection, block_number)?;
    }
    Ok(())
}

fn set_initial_machine(
    connection: &mut Connection,
    state_dir: &Path,
    source_machine_path: &Path,
) -> Result<()> {
    assert!(
        state_dir.is_dir(),
        "`{}` should be a directory",
        state_dir.display()
    );
    assert!(
        source_machine_path.is_dir(),
        "machine path `{}` must be an existing directory",
        source_machine_path.display()
    );

    let mut machine = RollupsMachine::new(source_machine_path, 0, 0)?;

    let (dest_machine_path, state_hash) = {
        let snapshots_path = snapshots_path(state_dir);
        machine
            .store_if_needed(&snapshots_path)
            .map_err(anyhow::Error::from)?
    };

    let tx = connection.transaction().map_err(anyhow::Error::from)?;
    rollup_data::insert_snapshot(&tx, 0, 0, &state_hash, &dest_machine_path)?;
    rollup_data::insert_template_machine(&tx, &state_hash)?;
    tx.commit().map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn set_scalar_function(connection: &Connection) -> Result<()> {
    connection
        .create_scalar_function(
            "fs_delete_dir",
            1,
            FunctionFlags::SQLITE_UTF8,
            fs_delete_dir,
        )
        .map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn create_connection(state_dir: &Path) -> Result<Connection> {
    let db_path = db_path(state_dir);
    let connection = Connection::open(db_path).map_err(anyhow::Error::from)?;
    connection
        .busy_timeout(std::time::Duration::from_secs(10))
        .map_err(anyhow::Error::from)?;

    // Enable WAL mode for concurrent access (ex: lua node)
    connection
        .query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))
        .map_err(anyhow::Error::from)?;

    set_scalar_function(&connection)?;

    Ok(connection)
}

pub fn migrate(
    state_dir: &Path,
    initial_machine_path: &Path,
    genesis_block_number: u64,
) -> Result<Connection> {
    create_directory_structure(state_dir)?;
    let mut connection = create_connection(state_dir)?;
    migrations::migrate_to_latest(&mut connection).map_err(anyhow::Error::from)?;
    set_genesis(&connection, genesis_block_number)?;
    set_initial_machine(&mut connection, state_dir, initial_machine_path)?;

    Ok(connection)
}

//
// Directory structure
//

pub fn create_empty_state_dir_if_needed(state_dir: &Path) -> Result<()> {
    fs::create_dir_all(state_dir).with_context(|| format!("creating `{}`", state_dir.display()))?;
    Ok(())
}

pub fn db_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("db.sqlite3")
}

pub fn snapshots_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("snapshots")
}

pub fn create_directory_structure(state_dir: &Path) -> Result<()> {
    create_empty_state_dir_if_needed(state_dir)?;

    let snapshots_path = snapshots_path(state_dir);

    fs::create_dir_all(&snapshots_path)
        .with_context(|| format!("creating `{}`", &snapshots_path.display()))?;

    Ok(())
}

fn epoch_dir(state_dir: &Path, epoch_number: u64) -> PathBuf {
    state_dir.join(epoch_number.to_string())
}

pub fn create_epoch_dir(state_dir: &Path, epoch_number: u64) -> Result<PathBuf> {
    let path = epoch_dir(state_dir, epoch_number);
    fs::create_dir_all(&path).with_context(|| format!("creating `{}`", &path.display()))?;

    Ok(path)
}
