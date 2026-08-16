// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The boundary store: the one component every machine store, load,
//! and clean in the node goes through.
//!
//! Identity is the input boundary - "the machine before input k",
//! yielded with a pristine uarch - because the window-opening
//! transition is fused (delivery with revert root + first ustep, one
//! leaf): post-feed states have no meta-cycle coordinate and are
//! never stored. Under the (epoch, input) map sits a content-
//! addressed store (directories named by machine root hash), which
//! is what makes registration idempotent: identical states dedup,
//! store races are benign, and a recomputation that disagrees with
//! its row fails loudly (write-once cell semantics, enforced by the
//! schema triggers).
//!
//! Reads are best-effort floors: any stored point at or before the
//! target only shortens replays, so rows whose directories vanished
//! are skipped, and the epoch start is the guaranteed answer of last
//! resort. Provenance is the writer's contract: a row must name the
//! boundary its machine truly sits at; the quartet cache's collision
//! tripwire cross-checks resumed against replayed computation
//! wherever they overlap.
//!
//! The write side is filesystem-first, database-second: machines
//! land in the store via a staging directory and an atomic rename
//! (the commit point - a crash can never leave a partial directory
//! at a final path), rows commit after, and directories orphaned by
//! GC are removed only after the transaction that unreferenced them.
//! A crash can orphan a directory, never dangle a row.

use super::convert::{blob_to_hash, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use super::open::{Storage, snapshots_path};
use super::rollups_machine::RollupsMachine;
use crate::engine::InputBoundary;

use cartesi_machine::error::MachineError;
use cartesi_machine::machine::Machine;
use cartesi_machine::types::Hash;
use rusqlite::{OptionalExtension, Transaction, params};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum StoreError {
    #[error(transparent)]
    Machine(#[from] MachineError),

    #[error("Failed to cleanup partial store {fs_err}, caused by {machine_err}")]
    Cleanup {
        machine_err: MachineError,
        fs_err: std::io::Error,
    },

    #[error("Failed to stage snapshot store: {0}")]
    Staging(std::io::Error),
}

//
// Stores
//

impl Storage {
    /// Stores the machine into the content-addressed path via a
    /// staging directory and an atomic rename. The rename is the
    /// commit point: a crash mid-store can never leave a partial
    /// directory at the final path, so the exists() gate stays
    /// trustworthy on resume. Stale staging directories (crash
    /// leftovers) are swept before reuse. Registration in the
    /// (epoch, input) map is the caller's transaction's business.
    pub(super) fn store_boundary(
        &self,
        machine: &mut RollupsMachine,
    ) -> std::result::Result<(PathBuf, Hash), StoreError> {
        let state_hash = machine.state_hash()?;
        let dest = self.stage_machine_store(&state_hash, |staging| machine.store_dir(staging))?;
        Ok((dest, state_hash))
    }

    /// The dispute write-back: commits a raw machine sitting at an
    /// input boundary - stored only when the content-addressed
    /// directory is absent, then registered. The row's write-once
    /// cell makes the whole verb idempotent AND a cross-regime
    /// nondeterminism tripwire: a replay that reaches a boundary
    /// regime 1 recorded must produce the identical hash or fail
    /// loudly. Returns the committed directory (the caller's revert
    /// point).
    pub fn commit_boundary_machine(
        &mut self,
        epoch_number: u64,
        input_number: u64,
        state_hash: &Hash,
        machine: &mut Machine,
    ) -> Result<PathBuf> {
        let dest = self
            .stage_machine_store(state_hash, |staging| machine.store(staging))
            .map_err(anyhow::Error::from)?;
        self.insert_boundary(epoch_number, input_number, state_hash, &dest)?;
        Ok(dest)
    }

    /// The staging discipline shared by every machine store: write
    /// into a uniquely named staging directory, then atomically
    /// rename to the content-addressed path. The rename is the
    /// commit point: a crash mid-store can never leave a partial
    /// directory at the final path, so the exists() gate stays
    /// trustworthy on resume. Staging names are unique per store
    /// (never keyed by hash: the hero and the roll can store an
    /// identical state concurrently); crash leftovers die in the
    /// startup sweep.
    fn stage_machine_store(
        &self,
        state_hash: &Hash,
        store: impl FnOnce(&Path) -> cartesi_machine::error::MachineResult<()>,
    ) -> std::result::Result<PathBuf, StoreError> {
        let snapshots = snapshots_path(self.state_dir());
        let dest = machine_store_path(&snapshots, state_hash);

        if !dest.exists() {
            static SEQ: AtomicU64 = AtomicU64::new(0);
            let staging = snapshots.join(format!(
                ".part-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, Ordering::Relaxed)
            ));

            if let Err(machine_err) = store(&staging) {
                // cleanup partial store before returning error.
                let fs_status = std::fs::remove_dir_all(&staging);

                if let Err(fs_err) = fs_status {
                    return Err(StoreError::Cleanup {
                        machine_err,
                        fs_err,
                    });
                } else {
                    return Err(machine_err.into());
                }
            }

            if let Err(rename_err) = std::fs::rename(&staging, &dest) {
                // Content addressing makes a lost race benign: an
                // existing destination has identical content.
                if dest.exists() {
                    let _ = std::fs::remove_dir_all(&staging);
                } else {
                    return Err(StoreError::Staging(rename_err));
                }
            }
        }

        Ok(dest)
    }

    /// A writable working clone of a stored machine, in the store's
    /// staging namespace: scratch until committed, invisible to rows,
    /// swept at startup if orphaned by a crash. Cheap where the
    /// filesystem reflinks; a sparse copy elsewhere.
    pub(super) fn checkout(&self, from: &Path) -> std::result::Result<PathBuf, StoreError> {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let working = snapshots_path(self.state_dir()).join(format!(
            ".work-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        Machine::clone_stored(from, &working)?;
        Ok(working)
    }

    /// Commits a working clone as the machine's content-addressed
    /// directory: the atomic rename is the commit point, and an
    /// already-existing destination has identical content (the CAS
    /// dedup - rejected inputs, idle stretches), so the clone is
    /// simply discarded against it. The caller must have closed the
    /// machine first. Row registration is separate, as everywhere.
    pub(super) fn commit_clone(
        &self,
        working: PathBuf,
        state_hash: &Hash,
    ) -> std::result::Result<PathBuf, StoreError> {
        let dest = machine_store_path(&snapshots_path(self.state_dir()), state_hash);
        if dest.exists() {
            std::fs::remove_dir_all(&working).map_err(StoreError::Staging)?;
        } else if let Err(rename_err) = std::fs::rename(&working, &dest) {
            return Err(StoreError::Staging(rename_err));
        }
        Ok(dest)
    }

    /// Removes an abandoned working clone (a poisoned post-reject
    /// state, or the spare clone a finished batch leaves behind).
    pub(super) fn discard_clone(&self, working: &Path) -> std::result::Result<(), StoreError> {
        std::fs::remove_dir_all(working).map_err(StoreError::Staging)
    }

    /// Startup ritual: removes staging leftovers a crash orphaned -
    /// partial stores (.part-*) and working clones (.work-*). Runs
    /// before any worker holds a clone; never touches committed
    /// directories.
    pub fn sweep_stale_staging(&self) -> Result<()> {
        let snapshots = snapshots_path(self.state_dir());
        let entries = match std::fs::read_dir(&snapshots) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(anyhow::Error::from(e).into()),
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if (name.starts_with(".part-") || name.starts_with(".work-"))
                && let Err(e) = std::fs::remove_dir_all(entry.path())
                && e.kind() != std::io::ErrorKind::NotFound
            {
                log::warn!(
                    "stale staging `{}` not removed: {e}",
                    entry.path().display()
                );
            }
        }
        Ok(())
    }

    /// Registers a stored machine directory as the boundary before
    /// `input_number` of `epoch_number`, in its own transaction.
    /// Idempotent by the write-once cell: an identical registration
    /// absorbs, a disagreeing hash or path fails loudly (schema
    /// triggers). Callers never check before writing.
    pub fn insert_boundary(
        &mut self,
        epoch_number: u64,
        input_number: u64,
        state_hash: &Hash,
        dir: &Path,
    ) -> Result<()> {
        self.write(|tx| insert_snapshot_in(tx, epoch_number, input_number, state_hash, dir))
    }
}

//
// Loads
//

impl Storage {
    /// The nearest stored boundary at or before `input` of the epoch,
    /// skipping rows whose directories vanished (a missing snapshot
    /// only lengthens a replay, never wrongs it). The epoch start is
    /// the floor; its absence is an error, not a miss.
    pub fn nearest_boundary_at_or_before(
        &mut self,
        epoch_number: u64,
        input: u64,
    ) -> Result<(InputBoundary, PathBuf)> {
        let candidates = self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT e.input_number, s.file_path
                    FROM epoch_snapshot_info AS e
                    JOIN machine_state_snapshots AS s
                    ON s.state_hash = e.state_hash
                    WHERE e.epoch_number = ?1 AND e.input_number <= ?2
                    ORDER BY e.input_number DESC
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            let rows = stmt
                .query_map(
                    params![u64_to_i64(epoch_number), u64_to_i64(input)],
                    |row| {
                        Ok((
                            InputBoundary(i64_to_u64(row.get::<_, i64>(0)?)),
                            PathBuf::from(row.get::<_, String>(1)?),
                        ))
                    },
                )
                .map_err(anyhow::Error::from)?;

            Ok(rows
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)?)
        })?;

        candidates
            .into_iter()
            .find(|(_, path)| path.exists())
            .ok_or_else(|| StorageError::DataNotFound {
                description: format!(
                    "no stored boundary at or before input {input} of epoch {epoch_number} \
                     (the epoch start is the guaranteed floor)"
                ),
            })
    }

    /// Loads the machine stored at a boundary, positioned to process
    /// that boundary's input next.
    pub fn snapshot(
        &mut self,
        epoch_number: u64,
        input_number: u64,
    ) -> Result<Option<RollupsMachine>> {
        let path = self.snapshot_dir(epoch_number, input_number)?;
        let ret = if let Some(path) = path {
            Some(RollupsMachine::new(&path, epoch_number, input_number)?)
        } else {
            None
        };

        Ok(ret)
    }

    pub fn snapshot_dir(
        &mut self,
        epoch_number: u64,
        input_number: u64,
    ) -> Result<Option<PathBuf>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT s.file_path
                    FROM epoch_snapshot_info AS e
                    JOIN machine_state_snapshots AS s
                    ON s.state_hash = e.state_hash
                    WHERE e.epoch_number = ?1 AND e.input_number = ?2
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            Ok(stmt
                .query_row(
                    params![u64_to_i64(epoch_number), u64_to_i64(input_number)],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(anyhow::Error::from)?
                .map(PathBuf::from))
        })
    }

    /// The state hash a boundary row names: the CAS key, and for the
    /// epoch start the level-0 implicit hash. Trusting the row spares
    /// a whole machine load where only the hash is needed.
    pub fn snapshot_hash(&mut self, epoch_number: u64, input_number: u64) -> Result<Option<Hash>> {
        self.read(|tx| {
            let row = tx
                .prepare_cached(
                    r#"
                    SELECT state_hash FROM epoch_snapshot_info
                    WHERE epoch_number = ?1 AND input_number = ?2
                    "#,
                )
                .map_err(anyhow::Error::from)?
                .query_row(
                    params![u64_to_i64(epoch_number), u64_to_i64(input_number)],
                    |row| row.get::<_, Vec<u8>>(0),
                )
                .optional()
                .map_err(anyhow::Error::from)?;

            row.map(blob_to_hash).transpose()
        })
    }

    pub fn latest_snapshot(&mut self) -> Result<RollupsMachine> {
        let (path, epoch_number, input_number, _) = self.read(latest_boundary_in)?;
        Ok(RollupsMachine::new(&path, epoch_number, input_number)?)
    }

    /// All surviving snapshot boundaries of an epoch, ordered by
    /// input. Boundaries are typed: a stored machine sits yielded at
    /// the input window it names.
    pub fn epoch_snapshots(&mut self, epoch_number: u64) -> Result<Vec<(InputBoundary, PathBuf)>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT e.input_number, s.file_path
                    FROM epoch_snapshot_info AS e
                    JOIN machine_state_snapshots AS s
                    ON s.state_hash = e.state_hash
                    WHERE e.epoch_number = ?1
                    ORDER BY e.input_number ASC
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            let rows = stmt
                .query_map([u64_to_i64(epoch_number)], |row| {
                    Ok((
                        InputBoundary(i64_to_u64(row.get::<_, i64>(0)?)),
                        PathBuf::from(row.get::<_, String>(1)?),
                    ))
                })
                .map_err(anyhow::Error::from)?;

            Ok(rows
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)?)
        })
    }
}

/// The newest snapshot boundary: (path, epoch, input, state_hash) -
/// the machine runner's resume point. At least one exists from the
/// migration's epoch-0 seed; its absence means a foreign or torn
/// database.
pub(super) fn latest_boundary_in(tx: &Transaction) -> Result<(PathBuf, u64, u64, Hash)> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            SELECT s.file_path, e.epoch_number, e.input_number, e.state_hash
            FROM epoch_snapshot_info AS e
            JOIN machine_state_snapshots AS s
            ON s.state_hash = e.state_hash
            ORDER BY e.epoch_number DESC, e.input_number DESC
            LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let row = stmt
        .query_row([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, Vec<u8>>(3)?,
            ))
        })
        .optional()
        .map_err(anyhow::Error::from)?;

    let (path, epoch, input, hash) = row.ok_or_else(|| StorageError::DataNotFound {
        description: "snapshot boundary (the migration seeds epoch 0)".into(),
    })?;

    Ok((
        path.into(),
        i64_to_u64(epoch),
        i64_to_u64(input),
        blob_to_hash(hash)?,
    ))
}

//
// Row registration (transaction-level, for the writer roles)
//

/// Registers a stored machine and indexes it as a boundary. Both
/// inserts absorb identical replays; the schema triggers abort a
/// disagreeing hash or path.
pub(super) fn insert_snapshot_in(
    tx: &Transaction,
    epoch_number: u64,
    input_number: u64,
    state_hash: &Hash,
    dest_dir: &Path,
) -> Result<()> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO machine_state_snapshots(state_hash, file_path)
            VALUES(?1, ?2)
            ON CONFLICT(state_hash) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;
    stmt.execute(params![state_hash, dest_dir.to_string_lossy()])
        .map_err(anyhow::Error::from)?;

    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO epoch_snapshot_info(epoch_number, input_number, state_hash)
            VALUES(?1, ?2, ?3)
            ON CONFLICT(epoch_number, input_number) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;
    stmt.execute(params![
        u64_to_i64(epoch_number),
        u64_to_i64(input_number),
        state_hash
    ])
    .map_err(anyhow::Error::from)?;

    Ok(())
}

pub(super) fn insert_template_machine_in(tx: &Transaction, state_hash: &Hash) -> Result<()> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT OR IGNORE INTO template_machine (id, state_hash)
            VALUES(1, ?1)
            "#,
        )
        .map_err(anyhow::Error::from)?;
    stmt.execute(params![state_hash])
        .map_err(anyhow::Error::from)?;

    Ok(())
}

//
// Garbage collection
//

/// Garbage-collects the epoch's intermediate boundaries, keeping the
/// epoch start, the anchor (the latest), and every snapshot_gap-th
/// input boundary - the preemptive material dispute replays resume
/// from. A gap of 1 keeps
/// everything. Returns the directories orphaned by the sweep; the
/// caller removes them after the transaction commits.
pub(super) fn gc_previous_advances_in(
    tx: &Transaction,
    epoch: u64,
    input_anchor: u64,
    snapshot_gap: u64,
) -> Result<Vec<PathBuf>> {
    assert!(snapshot_gap >= 1, "a zero gap keeps nothing to divide by");
    tx.execute(
        r#"
        DELETE FROM epoch_snapshot_info
        WHERE epoch_number = ?1 AND (input_number != ?2 AND input_number != 0)
          AND (input_number % ?3) != 0
        "#,
        params![
            u64_to_i64(epoch),
            u64_to_i64(input_anchor),
            u64_to_i64(snapshot_gap)
        ],
    )
    .map_err(anyhow::Error::from)?;

    sweep_unreferenced_snapshots_in(tx)
}

/// Deletes content-addressed rows nothing references, returning their
/// directories. The FK RESTRICT on template_machine and
/// epoch_snapshot_info backs the NOT IN exclusions.
pub(super) fn sweep_unreferenced_snapshots_in(tx: &Transaction) -> Result<Vec<PathBuf>> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            DELETE FROM machine_state_snapshots
            WHERE state_hash NOT IN (
                SELECT state_hash FROM epoch_snapshot_info
                UNION
                SELECT state_hash FROM template_machine
            )
            RETURNING file_path
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(anyhow::Error::from)?;

    Ok(rows
        .collect::<rusqlite::Result<Vec<String>>>()
        .map_err(anyhow::Error::from)?
        .into_iter()
        .map(PathBuf::from)
        .collect())
}

impl Storage {
    /// Removes settled epochs' scratch directories (dispute work
    /// under `state_dir/<epoch>/`), the filesystem sibling of
    /// gc_old_epochs_in and safe by the same argument: with the
    /// machine at epoch M, epochs at or below M - 2 belong to
    /// settled disputes. The roll path sweeps as epochs settle; this
    /// entry point is the startup ritual's, catching dirs a crash or
    /// an older node version left behind.
    pub fn sweep_settled_epoch_scratch(&mut self) -> Result<()> {
        let machine_epoch = self.next_input_id()?.epoch_number;
        if let Some(max_settled) = machine_epoch.checked_sub(2) {
            sweep_scratch_dirs_at_or_below(self.state_dir(), max_settled);
        }
        Ok(())
    }
}

/// Best effort: a surviving scratch dir costs disk, never
/// correctness, and the next sweep retries it.
pub(super) fn sweep_scratch_dirs_at_or_below(state_dir: &Path, max_epoch: u64) {
    let Ok(entries) = std::fs::read_dir(state_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(epoch) = name.to_str().and_then(|s| s.parse::<u64>().ok()) else {
            continue; // db, snapshots/, and anything else non-numeric
        };
        if epoch <= max_epoch
            && let Err(e) = std::fs::remove_dir_all(entry.path())
            && e.kind() != std::io::ErrorKind::NotFound
        {
            log::warn!(
                "settled epoch scratch `{}` not removed: {e}",
                entry.path().display()
            );
        }
    }
}

/// Best-effort, strictly after the commit that unreferenced the rows:
/// a failure leaves an orphan directory (harmless, re-adopted by a
/// later identical store), never a row pointing at nothing.
pub(super) fn remove_orphan_dirs(paths: &[PathBuf]) {
    for path in paths {
        if let Err(e) = std::fs::remove_dir_all(path)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            log::warn!("orphan snapshot dir `{}` not removed: {e}", path.display());
        }
    }
}

fn machine_store_path(snapshots_path: &Path, state_hash: &Hash) -> PathBuf {
    snapshots_path.join(format!("0x{}", hex::encode(state_hash)))
}

#[cfg(test)]
mod tests {
    use super::super::sql::test_helper::setup_storage;
    use super::*;

    #[test]
    fn insert_snapshot_and_latest_boundary() {
        let (_handle, mut s) = setup_storage();
        let dir = tempfile::TempDir::new().unwrap();

        s.insert_boundary(42, 2, &[1u8; 32], dir.path()).unwrap();

        let id = s.next_input_id().unwrap();
        assert_eq!(id.epoch_number, 42);
        assert_eq!(id.input_index_in_epoch, 2);

        assert_eq!(s.snapshot_dir(42, 2).unwrap().unwrap(), dir.path());
        assert!(s.snapshot_dir(99, 99).unwrap().is_none());
        assert_eq!(s.snapshot_hash(42, 2).unwrap().unwrap(), [1u8; 32]);
        assert!(s.snapshot_hash(99, 99).unwrap().is_none());
    }

    /// Idempotence: an identical registration absorbs.
    #[test]
    fn insert_boundary_absorbs_identical() {
        let (_handle, mut s) = setup_storage();
        let dir = tempfile::TempDir::new().unwrap();

        s.insert_boundary(7, 3, &[5u8; 32], dir.path()).unwrap();
        s.insert_boundary(7, 3, &[5u8; 32], dir.path()).unwrap();
    }

    /// A disagreeing hash for the same boundary is nondeterminism:
    /// the write-once cell PANICS (the tick loops retry errors
    /// forever; only a panic reaches the node's loud exit).
    #[test]
    #[should_panic(expected = "tripwire")]
    fn insert_boundary_disagreement_panics() {
        let (_handle, mut s) = setup_storage();
        let dir = tempfile::TempDir::new().unwrap();

        s.insert_boundary(7, 3, &[5u8; 32], dir.path()).unwrap();
        let _ = s.insert_boundary(7, 3, &[6u8; 32], dir.path());
    }

    /// The dispute write-back verb: stores only when the CAS misses,
    /// absorbs identical recommits, and fails loudly on a divergent
    /// hash for a written boundary (the cross-regime tripwire).
    #[test]
    fn commit_boundary_machine_is_idempotent_and_loud() {
        let (_handle, mut s) = setup_storage();
        let template = s.snapshot_dir(0, 0).unwrap().unwrap();
        let mut machine = cartesi_machine::machine::Machine::load(
            &template,
            &cartesi_machine::config::runtime::RuntimeConfig::quiet_console(),
        )
        .unwrap();
        let hash = machine.root_hash().unwrap();

        // The CAS already holds this state (it is the template), so
        // the commit only registers the row.
        let dest = s
            .commit_boundary_machine(7, 3, &hash, &mut machine)
            .unwrap();
        assert_eq!(dest, template);
        assert_eq!(s.snapshot_dir(7, 3).unwrap().unwrap(), dest);

        // An identical recommit absorbs.
        s.commit_boundary_machine(7, 3, &hash, &mut machine)
            .unwrap();

        // A boundary whose state the CAS misses gets stored: a real
        // machine store lands under the new key.
        let mut other = hash;
        other[0] ^= 0xFF;
        let dest2 = s
            .commit_boundary_machine(7, 4, &other, &mut machine)
            .unwrap();
        assert_ne!(dest2, dest);
        assert!(dest2.join("config.json").exists());
    }

    /// A divergent hash for a written boundary is nondeterminism (the
    /// cross-regime tripwire): PANIC, never a retryable error.
    #[test]
    #[should_panic(expected = "tripwire")]
    fn commit_boundary_machine_divergence_panics() {
        let (_handle, mut s) = setup_storage();
        let template = s.snapshot_dir(0, 0).unwrap().unwrap();
        let mut machine = cartesi_machine::machine::Machine::load(
            &template,
            &cartesi_machine::config::runtime::RuntimeConfig::quiet_console(),
        )
        .unwrap();
        let hash = machine.root_hash().unwrap();
        s.commit_boundary_machine(7, 3, &hash, &mut machine)
            .unwrap();

        let mut divergent = hash;
        divergent[0] ^= 0xFF;
        let _ = s.commit_boundary_machine(7, 3, &divergent, &mut machine);
    }

    /// The floor query answers the nearest surviving boundary,
    /// skipping rows whose directories vanished.
    #[test]
    fn nearest_boundary_answers_the_floor_and_self_heals() {
        let (_handle, mut s) = setup_storage();
        let kept: Vec<tempfile::TempDir> =
            (0..3).map(|_| tempfile::TempDir::new().unwrap()).collect();
        let vanishing = tempfile::TempDir::new().unwrap();

        s.insert_boundary(5, 0, &[1u8; 32], kept[0].path()).unwrap();
        s.insert_boundary(5, 10, &[2u8; 32], kept[1].path())
            .unwrap();
        s.insert_boundary(5, 20, &[3u8; 32], vanishing.path())
            .unwrap();
        s.insert_boundary(5, 30, &[4u8; 32], kept[2].path())
            .unwrap();

        let expect = |s: &mut Storage, input: u64, at: u64, path: &Path| {
            let (b, d) = s.nearest_boundary_at_or_before(5, input).unwrap();
            assert_eq!((b, d.as_path()), (InputBoundary(at), path));
        };
        expect(&mut s, 0, 0, kept[0].path());
        expect(&mut s, 9, 0, kept[0].path());
        expect(&mut s, 10, 10, kept[1].path());
        expect(&mut s, 25, 20, vanishing.path());
        expect(&mut s, 1 << 23, 30, kept[2].path());

        // Boundary 20's directory vanishes; its row is skipped and
        // the floor falls back to 10.
        drop(vanishing);
        expect(&mut s, 25, 10, kept[1].path());

        // A different epoch has no floor at all.
        assert!(s.nearest_boundary_at_or_before(6, 100).is_err());
    }

    #[test]
    fn gc_previous_advances_keeps_gap_boundaries() {
        let (_handle, mut s) = setup_storage();
        let epoch = 5u64;

        let survivors = |s: &mut Storage| -> Vec<u64> {
            s.epoch_snapshots(epoch)
                .unwrap()
                .into_iter()
                .map(|(boundary, _)| boundary.0)
                .collect()
        };

        let dirs: Vec<tempfile::TempDir> =
            (0..10).map(|_| tempfile::TempDir::new().unwrap()).collect();
        for (input, dir) in dirs.iter().enumerate() {
            let hash = [input as u8 + 1; 32];
            s.insert_boundary(epoch, input as u64, &hash, dir.path())
                .unwrap();
        }

        let orphans = s
            .write(|tx| gc_previous_advances_in(tx, epoch, 9, 4))
            .unwrap();
        assert_eq!(survivors(&mut s), vec![0, 4, 8, 9]);
        assert_eq!(orphans.len(), 6, "six boundaries fell to the gap");

        // A gap larger than any input keeps only the start and anchor.
        let (_handle2, mut s2) = setup_storage();
        let dirs2: Vec<tempfile::TempDir> =
            (0..4).map(|_| tempfile::TempDir::new().unwrap()).collect();
        for (input, dir) in dirs2.iter().enumerate() {
            let hash = [input as u8 + 1; 32];
            s2.insert_boundary(epoch, input as u64, &hash, dir.path())
                .unwrap();
        }
        s2.write(|tx| gc_previous_advances_in(tx, epoch, 2, 1000).map(|_| ()))
            .unwrap();
        assert_eq!(
            s2.epoch_snapshots(epoch)
                .unwrap()
                .into_iter()
                .map(|(b, _)| b.0)
                .collect::<Vec<_>>(),
            vec![0, 2]
        );

        // A gap of 1 keeps every boundary.
        let (_handle3, mut s3) = setup_storage();
        let dirs3: Vec<tempfile::TempDir> =
            (0..5).map(|_| tempfile::TempDir::new().unwrap()).collect();
        for (input, dir) in dirs3.iter().enumerate() {
            let hash = [input as u8 + 1; 32];
            s3.insert_boundary(epoch, input as u64, &hash, dir.path())
                .unwrap();
        }
        s3.write(|tx| gc_previous_advances_in(tx, epoch, 4, 1).map(|_| ()))
            .unwrap();
        assert_eq!(
            s3.epoch_snapshots(epoch)
                .unwrap()
                .into_iter()
                .map(|(b, _)| b.0)
                .collect::<Vec<_>>(),
            vec![0, 1, 2, 3, 4]
        );
    }

    /// Orphaned directories are removed only after the commit; the
    /// returned paths are exactly the swept rows' directories.
    #[test]
    fn gc_returns_orphan_directories_for_post_commit_removal() {
        let (_handle, mut s) = setup_storage();
        let keep = tempfile::TempDir::new().unwrap();
        let drop_ = tempfile::TempDir::new().unwrap();

        s.insert_boundary(3, 0, &[1u8; 32], keep.path()).unwrap();
        s.insert_boundary(3, 1, &[2u8; 32], drop_.path()).unwrap();

        let orphans = s
            .write(|tx| gc_previous_advances_in(tx, 3, 2, 1000))
            .unwrap();
        assert_eq!(orphans, vec![drop_.path().to_path_buf()]);
    }

    /// The scratch sweep takes numeric dirs at or below the settled
    /// boundary and nothing else: newer epochs, the database, and the
    /// snapshot store are untouchable.
    #[test]
    fn scratch_sweep_spares_live_epochs_and_non_epoch_entries() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["0", "1", "2", "5", "snapshots"] {
            std::fs::create_dir(dir.path().join(name)).unwrap();
        }
        std::fs::write(dir.path().join("db.sqlite3"), b"x").unwrap();

        sweep_scratch_dirs_at_or_below(dir.path(), 2);

        for gone in ["0", "1", "2"] {
            assert!(!dir.path().join(gone).exists(), "{gone} should be swept");
        }
        for kept in ["5", "snapshots", "db.sqlite3"] {
            assert!(dir.path().join(kept).exists(), "{kept} should survive");
        }
    }
}
