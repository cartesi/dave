// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Stored machine directories, typed by what the emulator lets be done
//! with them.
//!
//! A machine opened on a directory with shared backing stores changes the
//! directory in place. The emulator's rule (cm.h, `cm_load`) separates
//! valid from durable: once that machine is destroyed, readers on the same
//! host see a stored machine again, and only a sync after that makes it
//! survive a stop of the system (a crash, a power loss). A directory whose
//! machine was not destroyed, or that a system stop caught unsynced, must
//! be discarded, even if it loads.
//!
//! - [`Volatile`] is closed and not synced. Destroying a machine leaves all
//!   of its state in the files' page cache, and a sync only makes it
//!   permanent, so this host can load and reopen the directory as it is. A
//!   clone of it is exact where the filesystem clones changes not yet
//!   written to disk: XFS guarantees it (a reflink writes the source's
//!   dirty pages back first, and fails if that fails), the emulator's
//!   copy fallback reads through the cache, and APFS does it today on no
//!   documented promise. It owns the directory and removes it when
//!   dropped: the discard rule, applied to every path that does not reach
//!   [`Volatile::persist`]. After a stop of the process, the caller
//!   discards what is left: nothing records which directories were closed.
//! - [`Durable`] was synced after its last writer closed. It is never
//!   opened shared, and nothing here removes it.
//!
//! [`Volatile::open`] moves the directory into the machine and only
//! [`Machine::close`] gives it back, so no code can load, clone or sync a
//! directory while a machine maps it for writing.

use std::path::{Path, PathBuf};

use crate::config::runtime::RuntimeConfig;
use crate::constants;
use crate::error::{MachineError, MachineResult as Result};
use crate::machine::Machine;

/// A stored machine directory that no machine maps for writing.
pub trait Stored {
    fn path(&self) -> &Path;

    /// Loads the machine with every file mapped privately: the directory is
    /// left as it is.
    fn load(&self, runtime_config: &RuntimeConfig) -> Result<Machine> {
        Machine::load(self.path(), runtime_config)
    }

    /// Clones the directory into `to`, which must not exist (see
    /// [`Machine::clone_stored`]). The clone is nobody's until synced.
    fn clone_to(&self, to: &Path) -> Result<Volatile> {
        let dir = absolute(to)?;
        Machine::clone_stored(self.path(), &dir)?;
        Ok(Volatile { dir })
    }
}

/// A closed stored machine that was not synced: good for this process,
/// gone with it. Removed when dropped.
#[derive(Debug)]
#[must_use = "a dropped volatile directory is removed"]
pub struct Volatile {
    /// Absolute: the drop removes what was taken, wherever the process's
    /// working directory went since.
    dir: PathBuf,
}

impl Volatile {
    /// Takes over `dir`, trusting that no machine maps it for writing: what
    /// [`Machine::store`] just wrote, for one.
    pub fn adopt(dir: impl AsRef<Path>) -> Result<Self> {
        Ok(Self {
            dir: absolute(dir.as_ref())?,
        })
    }

    /// Opens the machine with every file mapped shared, so its changes land
    /// in the directory, which the machine now owns. A failed open discards
    /// the directory.
    pub fn open(self, runtime_config: &RuntimeConfig) -> Result<Machine> {
        Machine::open_shared(self, runtime_config)
    }

    /// Syncs the directory and renames it to `to`, which must not exist, on
    /// the same filesystem. On failure the directory is discarded, unless
    /// the rename itself landed before failing.
    pub fn persist(self, to: &Path) -> Result<Durable> {
        Machine::sync_stored(&self.dir)?;
        Machine::rename_stored(&self.dir, to)?;
        // The directory moved: nothing is left here to remove.
        let _ = self.keep();
        Ok(Durable { dir: to.to_owned() })
    }

    /// Gives up the removal: the directory stays, and the discard rule
    /// becomes the caller's.
    pub fn keep(mut self) -> PathBuf {
        let dir = std::mem::take(&mut self.dir);
        std::mem::forget(self);
        dir
    }
}

impl Stored for Volatile {
    fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Volatile {
    fn drop(&mut self) {
        // Not cm_remove_stored: its durable removal buys nothing for a
        // directory that a stop discards anyway.
        match std::fs::remove_dir_all(&self.dir) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => log::warn!(
                "volatile stored machine `{}` not removed: {error}",
                self.dir.display()
            ),
        }
    }
}

/// Resolves `dir` against the working directory of now, without touching
/// the filesystem.
fn absolute(dir: &Path) -> Result<PathBuf> {
    std::path::absolute(dir).map_err(|error| MachineError {
        code: constants::error_code::INVALID_ARGUMENT,
        message: format!("unable to resolve `{}`: {error}", dir.display()),
    })
}

/// A stored machine that was synced after its last writer closed: a
/// template, a published snapshot.
#[derive(Clone, Debug)]
pub struct Durable {
    dir: PathBuf,
}

impl Durable {
    /// Trusts `dir` to hold such a machine. Nothing checks it.
    pub fn at(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Syncs the directory again, for one found already in place whose own
    /// sync may not have completed.
    pub fn sync(&self) -> Result<()> {
        Machine::sync_stored(&self.dir)
    }
}

impl Stored for Durable {
    fn path(&self) -> &Path {
        &self.dir
    }
}
