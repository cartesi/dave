// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod consensus_data;
pub mod migrations;
pub mod rollup_data;

#[cfg(test)]
pub(crate) mod test_helper;

use crate::state_manager::Result;
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
    set_scalar_function(&connection)?;

    Ok(connection)
}

//
// Directory structure
//

pub fn db_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("db.sqlite3")
}

pub fn snapshots_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("snapshots")
}

pub fn machine_path(state_dir: &Path, state_hash: &cartesi_machine::types::Hash) -> PathBuf {
    let snapshots = snapshots_path(state_dir);
    snapshots.join(format!("0x{}", hex::encode(state_hash)))
}

pub fn create_directory_structure(state_dir: &Path) -> Result<()> {
    fs::create_dir_all(state_dir).with_context(|| format!("creating `{}`", state_dir.display()))?;

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
