// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Stored machine directories, typed by what the emulator lets be done
//! with them.
//!
//! A machine opened on a directory with shared backing stores changes the
//! directory in place. The emulator's rule (cm.h, `cm_load` and
//! `cm_sync_stored`) has two halves: the directory is a stored machine
//! again only once that machine is destroyed, and it survives a stop of the
//! process (a crash, a kill, a power loss) only once it is synced after
//! that. Otherwise it must be discarded, even if it loads.
//!
//! - [`Volatile`] is closed and not synced. Destroying a machine leaves all
//!   of its state in the files' page cache, and a sync only makes it
//!   permanent, so this process can load, clone and reopen the directory
//!   as it is. It owns the directory and removes it when dropped: the
//!   discard rule, applied to every path that does not reach
//!   [`Volatile::persist`]. After a stop, the caller discards what is left.
//! - [`Durable`] was synced after its last writer closed. It is never
//!   opened shared, and nothing here removes it.
//!
//! [`Volatile::open`] moves the directory into the machine and only
//! [`Machine::close`] gives it back, so no code can load, clone or sync a
//! directory while a machine maps it for writing.

use std::path::{Path, PathBuf};

use crate::config::runtime::RuntimeConfig;
use crate::error::MachineResult as Result;
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
        Machine::clone_stored(self.path(), to)?;
        Ok(Volatile { dir: to.to_owned() })
    }
}

/// A closed stored machine that was not synced: good for this process,
/// gone with it. Removed when dropped.
#[derive(Debug)]
#[must_use = "a dropped volatile directory is removed"]
pub struct Volatile {
    dir: PathBuf,
}

impl Volatile {
    /// Takes over `dir`, trusting that no machine maps it for writing: what
    /// [`Machine::store`] just wrote, for one.
    pub fn adopt(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
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
