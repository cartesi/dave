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
//! addressed store (directories named by machine root hash, so a row's
//! hash is its path), which is what makes registration idempotent:
//! identical states dedup,
//! store races are benign, and a recomputation that disagrees with
//! its row fails loudly (write-once cell semantics, checked by
//! insert_snapshot_in).
//!
//! Dispute-positioning reads are best-effort floors: any stored point
//! at or before the target only shortens replays, so an unavailable
//! intermediate may be skipped. The runner's newest boundary is
//! different: it is the durable cursor, so a row whose directory
//! vanished is a fatal storage-invariant violation. Provenance is the
//! writer's contract: a row must name the boundary its machine truly
//! sits at; runner loads verify that root before mutation, while the
//! quartet cache's collision tripwire cross-checks resumed against
//! replayed computation wherever they overlap.
//!
//! The write side is filesystem-first, database-second: staged
//! machines are root-verified, synced, and renamed durably without
//! replacement before their rows commit. A publication crash may
//! orphan a complete directory but cannot leave a row naming an
//! undurable machine. GC removes directories only after the
//! transaction that unreferenced them; its concurrency assumption is
//! documented in the node architecture.

use super::convert::{blob_to_hash, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use super::open::{Storage, snapshots_path};
use super::rollups_machine::RollupsMachine;
use crate::engine::InputBoundary;

use cartesi_machine::machine::Machine;
use cartesi_machine::types::Hash;
use rusqlite::{OptionalExtension, Transaction, params};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

//
// Stores
//

/// The runner's durable cursor must always have its stored machine.
/// It does not silently roll that cursor back to an earlier checkpoint;
/// replay and republication would be a separate recovery protocol. A
/// missing path therefore means a storage bug or an underlying
/// filesystem failure, not retryable work.
pub(super) fn assert_runner_boundary_dir(path: &Path, epoch: u64, input: u64) {
    match std::fs::metadata(path) {
        Ok(metadata) => assert!(
            metadata.is_dir(),
            "durable runner boundary is not a directory: epoch {epoch}, input {input}, path `{}`; database and filesystem disagree",
            path.display()
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => panic!(
            "durable runner boundary vanished: epoch {epoch}, input {input}, path `{}`; database and filesystem disagree",
            path.display()
        ),
        Err(error) => panic!(
            "durable runner boundary is inaccessible: epoch {epoch}, input {input}, path `{}`: {error}; database and filesystem cannot be verified",
            path.display()
        ),
    }
}

/// Verifies the database row against the machine loaded from its
/// directory before the runner can mutate it.
pub(super) fn assert_runner_boundary_root(
    machine: &mut RollupsMachine,
    expected: &Hash,
    path: &Path,
    epoch: u64,
    input: u64,
) {
    let actual = machine.state_hash().unwrap_or_else(|error| {
        panic!(
            "durable runner boundary root could not be verified: epoch {epoch}, input {input}, path `{}`: {error}",
            path.display()
        )
    });
    assert_eq!(
        actual,
        *expected,
        "durable runner boundary root mismatch: epoch {epoch}, input {input}, path `{}`; database row and stored machine disagree",
        path.display()
    );
}

impl Storage {
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
        let actual_hash = machine.root_hash()?;
        assert_eq!(
            actual_hash, *state_hash,
            "dispute boundary CAS key disagrees with the machine root"
        );
        let dest = self.stage_machine_store(state_hash, |staging| machine.store(staging))?;
        self.insert_boundary(epoch_number, input_number, state_hash)?;
        Ok(dest)
    }

    /// Serializes into a unique staging directory before durable CAS
    /// publication. Staging names are never keyed by hash: the hero's
    /// write-back and the runner's batch commit may publish an identical
    /// state concurrently, and publish_staged settles the race.
    fn stage_machine_store(
        &self,
        state_hash: &Hash,
        store: impl FnOnce(&Path) -> cartesi_machine::error::MachineResult<()>,
    ) -> anyhow::Result<PathBuf> {
        let snapshots = snapshots_path(self.state_dir());
        let dest = snapshot_path(self.state_dir(), state_hash);

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
                    anyhow::bail!(
                        "Failed to cleanup partial store {fs_err}, caused by {machine_err}"
                    );
                } else {
                    return Err(machine_err.into());
                }
            }

            return self.publish_staged(staging, state_hash);
        }

        // A concurrent publisher may have made the directory visible
        // before its own parent fsync completed. Adoption establishes
        // durability independently before any caller registers a row.
        Machine::sync_stored(&dest)?;
        Ok(dest)
    }

    /// The one durable CAS publication boundary. The staged machine
    /// is root-verified, synced, and renamed without replacement.
    /// Only a destination that won the same CAS race makes a failed
    /// rename benign. Database registration always follows this
    /// function at its caller.
    fn publish_staged(&self, staged: PathBuf, expected_hash: &Hash) -> anyhow::Result<PathBuf> {
        let actual_hash = {
            let mut verifier = Machine::load(
                &staged,
                &cartesi_machine::config::runtime::RuntimeConfig::quiet_console(),
            )?;
            verifier.root_hash()?
        };
        assert_eq!(
            actual_hash, *expected_hash,
            "staged machine root disagrees with its CAS key"
        );

        Machine::sync_stored(&staged)?;
        let dest = snapshot_path(self.state_dir(), expected_hash);

        if dest.exists() {
            Machine::sync_stored(&dest)?;
            let _ = std::fs::remove_dir_all(&staged);
            return Ok(dest);
        }

        if let Err(rename_err) = Machine::rename_stored(&staged, &dest) {
            if dest.exists() {
                // This may be a lost race, or our rename may have
                // succeeded before its directory fsync failed. In
                // either case, make the visible destination durable
                // ourselves before treating it as adopted.
                Machine::sync_stored(&dest)?;
                let _ = std::fs::remove_dir_all(&staged);
            } else {
                return Err(rename_err.into());
            }
        }

        Ok(dest)
    }

    /// A writable working clone of a stored machine, in the store's
    /// staging namespace: scratch until committed, invisible to rows,
    /// swept at startup if orphaned by a crash. Cheap where the
    /// filesystem reflinks; a sparse copy elsewhere.
    pub(super) fn checkout(&self, from: &Path) -> anyhow::Result<PathBuf> {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let working = snapshots_path(self.state_dir()).join(format!(
            ".work-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        Machine::clone_stored(from, &working)?;
        Ok(working)
    }

    /// Durably publishes a closed working clone. The staged machine
    /// derives and verifies its CAS key inside the shared publisher;
    /// row registration remains separate, as everywhere.
    pub(super) fn commit_clone(
        &self,
        working: PathBuf,
        state_hash: &Hash,
    ) -> anyhow::Result<PathBuf> {
        self.publish_staged(working, state_hash)
    }

    /// Removes an abandoned working clone (a poisoned post-reject
    /// state, or the spare clone a finished batch leaves behind).
    pub(super) fn discard_clone(&self, working: &Path) -> anyhow::Result<()> {
        std::fs::remove_dir_all(working)
            .map_err(|e| anyhow::anyhow!("Failed to stage snapshot store: {e}"))
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

    /// Registers the published machine `state_hash` names as the boundary
    /// before `input_number` of `epoch_number`, in its own transaction.
    /// Idempotent by the write-once cell: an identical registration
    /// absorbs, a disagreeing hash panics. Callers never check before
    /// writing.
    pub fn insert_boundary(
        &mut self,
        epoch_number: u64,
        input_number: u64,
        state_hash: &Hash,
    ) -> Result<()> {
        self.write(|tx| insert_snapshot_in(tx, epoch_number, input_number, state_hash))
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
            let mut stmt = tx.prepare_cached(
                r#"
                    SELECT input_number, state_hash
                    FROM epoch_snapshot_info
                    WHERE epoch_number = ?1 AND input_number <= ?2
                    ORDER BY input_number DESC
                    "#,
            )?;

            let rows = stmt.query_map(
                params![u64_to_i64(epoch_number), u64_to_i64(input)],
                |row| {
                    Ok((
                        InputBoundary(i64_to_u64(row.get::<_, i64>(0)?)),
                        row.get::<_, Vec<u8>>(1)?,
                    ))
                },
            )?;

            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })?;

        for (boundary, hash) in candidates {
            let path = snapshot_path(self.state_dir(), &blob_to_hash(hash)?);
            if path.exists() {
                return Ok((boundary, path));
            }
        }
        Err(StorageError::DataNotFound {
            description: format!(
                "no stored boundary at or before input {input} of epoch {epoch_number} \
                 (the epoch start is the guaranteed floor)"
            ),
        })
    }

    /// The directory of a registered boundary, whether or not it survives.
    pub fn snapshot_dir(
        &mut self,
        epoch_number: u64,
        input_number: u64,
    ) -> Result<Option<PathBuf>> {
        Ok(self
            .snapshot_hash(epoch_number, input_number)?
            .map(|hash| snapshot_path(self.state_dir(), &hash)))
    }

    /// The state hash a boundary row names: the CAS key, and for the
    /// epoch start the level-0 implicit hash. Trusting the row spares
    /// a whole machine load where only the hash is needed.
    pub fn snapshot_hash(&mut self, epoch_number: u64, input_number: u64) -> Result<Option<Hash>> {
        self.read(|tx| snapshot_hash_in(tx, epoch_number, input_number))
    }

    pub fn latest_snapshot(&mut self) -> Result<RollupsMachine> {
        let (epoch_number, input_number, expected_hash) = self.read(latest_boundary_in)?;
        let path = snapshot_path(self.state_dir(), &expected_hash);
        assert_runner_boundary_dir(&path, epoch_number, input_number);
        let mut machine = match RollupsMachine::new(&path, epoch_number, input_number) {
            Ok(machine) => machine,
            Err(error) => {
                // Promote a path that disappeared during the load to
                // the fatal invariant; other load errors can retry.
                assert_runner_boundary_dir(&path, epoch_number, input_number);
                return Err(error.into());
            }
        };
        assert_runner_boundary_root(
            &mut machine,
            &expected_hash,
            &path,
            epoch_number,
            input_number,
        );
        Ok(machine)
    }

    /// All surviving snapshot boundaries of an epoch, ordered by
    /// input. Boundaries are typed: a stored machine sits yielded at
    /// the input window it names.
    pub fn epoch_snapshots(&mut self, epoch_number: u64) -> Result<Vec<(InputBoundary, PathBuf)>> {
        let rows = self.read(|tx| {
            let mut stmt = tx.prepare_cached(
                r#"
                    SELECT input_number, state_hash
                    FROM epoch_snapshot_info
                    WHERE epoch_number = ?1
                    ORDER BY input_number ASC
                    "#,
            )?;

            let rows = stmt.query_map([u64_to_i64(epoch_number)], |row| {
                Ok((
                    InputBoundary(i64_to_u64(row.get::<_, i64>(0)?)),
                    row.get::<_, Vec<u8>>(1)?,
                ))
            })?;

            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })?;
        rows.into_iter()
            .map(|(boundary, hash)| {
                Ok((
                    boundary,
                    snapshot_path(self.state_dir(), &blob_to_hash(hash)?),
                ))
            })
            .collect()
    }
}

/// The newest snapshot boundary: (epoch, input, state_hash) - the
/// machine runner's resume point. At least one exists from the
/// initialization's seed; its absence means a foreign or torn database.
pub(super) fn latest_boundary_in(tx: &Transaction) -> Result<(u64, u64, Hash)> {
    let row = tx
        .prepare_cached(
            r#"
            SELECT epoch_number, input_number, state_hash
            FROM epoch_snapshot_info
            ORDER BY epoch_number DESC, input_number DESC
            LIMIT 1
            "#,
        )?
        .query_row([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })
        .optional()?;

    let (epoch, input, hash) = row.ok_or_else(|| StorageError::DataNotFound {
        description: "snapshot boundary (initialization seeds the start epoch)".into(),
    })?;

    Ok((i64_to_u64(epoch), i64_to_u64(input), blob_to_hash(hash)?))
}

/// The state hash the boundary row at (epoch, input) names, if any.
pub(super) fn snapshot_hash_in(
    tx: &Transaction,
    epoch_number: u64,
    input_number: u64,
) -> Result<Option<Hash>> {
    tx.prepare_cached(
        r#"
        SELECT state_hash FROM epoch_snapshot_info
        WHERE epoch_number = ?1 AND input_number = ?2
        "#,
    )?
    .query_row(
        params![u64_to_i64(epoch_number), u64_to_i64(input_number)],
        |row| row.get::<_, Vec<u8>>(0),
    )
    .optional()?
    .map(blob_to_hash)
    .transpose()
}

//
// Row registration (transaction-level, for the writer roles)
//

/// Indexes a published machine as a boundary: the write-once cell. An
/// identical replay absorbs; a disagreeing hash is nondeterminism and
/// panics, since the tick loops retry an error forever.
pub(super) fn insert_snapshot_in(
    tx: &Transaction,
    epoch_number: u64,
    input_number: u64,
    state_hash: &Hash,
) -> Result<()> {
    let inserted = tx
        .prepare_cached(
            r#"
        INSERT INTO epoch_snapshot_info(epoch_number, input_number, state_hash)
        VALUES(?1, ?2, ?3)
        ON CONFLICT(epoch_number, input_number) DO NOTHING
        "#,
        )?
        .execute(params![
            u64_to_i64(epoch_number),
            u64_to_i64(input_number),
            state_hash
        ])?;

    if inserted == 0 {
        let stored = snapshot_hash_in(tx, epoch_number, input_number)?
            .expect("conflicting boundary row exists by the conflict clause");
        assert_eq!(
            stored, *state_hash,
            "snapshot boundary (epoch {epoch_number}, input {input_number}) disagrees with \
             its stored row: nondeterminism or corruption"
        );
    }
    Ok(())
}

//
// Garbage collection
//

/// Deletes the boundaries of every epoch up to `max_epoch`, returning
/// the states no remaining boundary names: their directories are
/// orphans once this transaction commits. The seed image needs no row of
/// its own: its epoch's start row names it while anything can still need
/// it.
pub(super) fn release_boundaries_in(tx: &Transaction, max_epoch: u64) -> Result<Vec<Hash>> {
    let max_epoch = u64_to_i64(max_epoch);
    let orphans = tx
        .prepare_cached(
            "SELECT state_hash FROM epoch_snapshot_info WHERE epoch_number <= ?1
             EXCEPT
             SELECT state_hash FROM epoch_snapshot_info WHERE epoch_number > ?1",
        )?
        .query_map([max_epoch], |row| row.get::<_, Vec<u8>>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    tx.execute(
        "DELETE FROM epoch_snapshot_info WHERE epoch_number <= ?1",
        [max_epoch],
    )?;
    orphans.into_iter().map(blob_to_hash).collect()
}

/// Best-effort, strictly after the commit that unreferenced the rows:
/// a failure leaves an orphan directory (harmless, re-adopted by a
/// later identical store), never a row pointing at nothing.
pub(super) fn remove_orphan_dirs(state_dir: &Path, hashes: &[Hash]) {
    for path in hashes.iter().map(|hash| snapshot_path(state_dir, hash)) {
        if let Err(e) = std::fs::remove_dir_all(&path)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            log::warn!("orphan snapshot dir `{}` not removed: {e}", path.display());
        }
    }
}

/// Where the store keeps the machine whose root is `state_hash`.
pub(super) fn snapshot_path(state_dir: &Path, state_hash: &Hash) -> PathBuf {
    snapshots_path(state_dir).join(format!("0x{}", hex::encode(state_hash)))
}

#[cfg(test)]
mod tests {
    use super::super::sql::test_helper::{setup_storage, stub_snapshot};
    use super::*;

    #[test]
    fn insert_snapshot_and_latest_boundary() {
        let (_handle, mut s) = setup_storage();

        s.insert_boundary(42, 2, &[1u8; 32]).unwrap();

        let id = s.next_input_id().unwrap();
        assert_eq!(id.epoch_number, 42);
        assert_eq!(id.input_index_in_epoch, 2);

        assert_eq!(
            s.snapshot_dir(42, 2).unwrap().unwrap(),
            s.state_dir()
                .join("snapshots")
                .join(format!("0x{}", hex::encode([1u8; 32])))
        );
        assert!(s.snapshot_dir(99, 99).unwrap().is_none());
        assert_eq!(s.snapshot_hash(42, 2).unwrap().unwrap(), [1u8; 32]);
        assert!(s.snapshot_hash(99, 99).unwrap().is_none());
    }

    /// Idempotence: an identical registration absorbs.
    #[test]
    fn insert_boundary_absorbs_identical() {
        let (_handle, mut s) = setup_storage();

        s.insert_boundary(7, 3, &[5u8; 32]).unwrap();
        s.insert_boundary(7, 3, &[5u8; 32]).unwrap();
    }

    /// A disagreeing hash for the same boundary is nondeterminism:
    /// the write-once cell PANICS (the tick loops retry errors
    /// forever; only a panic reaches the node's loud exit).
    #[test]
    #[should_panic(expected = "disagrees with its stored row")]
    fn insert_boundary_disagreement_panics() {
        let (_handle, mut s) = setup_storage();

        s.insert_boundary(7, 3, &[5u8; 32]).unwrap();
        let _ = s.insert_boundary(7, 3, &[6u8; 32]);
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

        // A boundary whose state the CAS misses gets stored under the
        // root derived from the actual machine.
        machine
            .write_memory(cartesi_machine::constants::ar::RAM_START, &[0xA5])
            .unwrap();
        let other = machine.root_hash().unwrap();
        assert_ne!(other, hash);
        let dest2 = s
            .commit_boundary_machine(7, 4, &other, &mut machine)
            .unwrap();
        assert_ne!(dest2, dest);
        assert!(dest2.join("config.json").exists());
    }

    /// A divergent hash for a written boundary is nondeterminism (the
    /// cross-regime tripwire): PANIC, never a retryable error.
    #[test]
    #[should_panic(expected = "disagrees with its stored row")]
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

        machine
            .write_memory(cartesi_machine::constants::ar::RAM_START, &[0x5A])
            .unwrap();
        let divergent = machine.root_hash().unwrap();
        assert_ne!(divergent, hash);
        let _ = s.commit_boundary_machine(7, 3, &divergent, &mut machine);
    }

    #[test]
    #[should_panic(expected = "CAS key disagrees")]
    fn commit_boundary_machine_refuses_a_supplied_wrong_root() {
        let (_handle, mut s) = setup_storage();
        let template = s.snapshot_dir(0, 0).unwrap().unwrap();
        let mut machine = cartesi_machine::machine::Machine::load(
            &template,
            &cartesi_machine::config::runtime::RuntimeConfig::quiet_console(),
        )
        .unwrap();
        let mut wrong = machine.root_hash().unwrap();
        wrong[0] ^= 0xFF;

        let _ = s.commit_boundary_machine(7, 3, &wrong, &mut machine);
    }

    /// The floor query answers the nearest surviving boundary,
    /// skipping rows whose directories vanished.
    #[test]
    fn nearest_boundary_answers_the_floor_and_self_heals() {
        let (_handle, mut s) = setup_storage();
        let dirs: Vec<PathBuf> = (1..=4u8)
            .map(|byte| stub_snapshot(&s, &[byte; 32]))
            .collect();
        for (input, byte) in [(0, 1u8), (10, 2), (20, 3), (30, 4)] {
            s.insert_boundary(5, input, &[byte; 32]).unwrap();
        }

        let expect = |s: &mut Storage, input: u64, at: u64, path: &Path| {
            let (b, d) = s.nearest_boundary_at_or_before(5, input).unwrap();
            assert_eq!((b, d.as_path()), (InputBoundary(at), path));
        };
        expect(&mut s, 0, 0, &dirs[0]);
        expect(&mut s, 9, 0, &dirs[0]);
        expect(&mut s, 10, 10, &dirs[1]);
        expect(&mut s, 25, 20, &dirs[2]);
        expect(&mut s, 1 << 23, 30, &dirs[3]);

        // Boundary 20's directory vanishes; its row is skipped and
        // the floor falls back to 10.
        std::fs::remove_dir(&dirs[2]).unwrap();
        expect(&mut s, 25, 10, &dirs[1]);

        // A different epoch has no floor at all.
        assert!(s.nearest_boundary_at_or_before(6, 100).is_err());
    }

    /// GC never removes a directory a crossing can adopt (the argument is in
    /// node-architecture.md); one that vanished anyway is skipped by
    /// positioning and republished by the next crossing.
    #[test]
    fn a_vanished_dispute_boundary_is_republished() {
        let (_handle, mut s) = setup_storage();
        let template = s.snapshot_dir(0, 0).unwrap().unwrap();
        let mut machine = cartesi_machine::machine::Machine::load(
            &template,
            &cartesi_machine::config::runtime::RuntimeConfig::quiet_console(),
        )
        .unwrap();
        let start = machine.root_hash().unwrap();
        s.commit_boundary_machine(7, 0, &start, &mut machine)
            .unwrap();
        machine
            .write_memory(cartesi_machine::constants::ar::RAM_START, &[0xA5])
            .unwrap();
        let hash = machine.root_hash().unwrap();
        let dest = s
            .commit_boundary_machine(7, 4, &hash, &mut machine)
            .unwrap();

        std::fs::remove_dir_all(&dest).unwrap();
        let (floor, _) = s.nearest_boundary_at_or_before(7, 4).unwrap();
        assert_eq!(floor, InputBoundary(0));

        let republished = s
            .commit_boundary_machine(7, 4, &hash, &mut machine)
            .unwrap();
        assert_eq!(republished, dest);
        assert!(dest.join("config.json").exists());
        assert_eq!(s.snapshot_hash(7, 4).unwrap(), Some(hash));
        let (floor, _) = s.nearest_boundary_at_or_before(7, 4).unwrap();
        assert_eq!(floor, InputBoundary(4));
    }

    /// A release orphans exactly the states no remaining boundary names,
    /// once each: a state a later epoch shares survives.
    #[test]
    fn release_orphans_only_states_nothing_still_names() {
        let (_handle, mut s) = setup_storage();
        let template = s.snapshot_hash(0, 0).unwrap().unwrap();
        for (epoch, input, byte) in [(1, 0, 1u8), (1, 1, 2), (1, 2, 2), (2, 0, 1)] {
            s.insert_boundary(epoch, input, &[byte; 32]).unwrap();
        }

        let mut orphans = s.write(|tx| release_boundaries_in(tx, 1)).unwrap();
        orphans.sort();
        let mut expected = vec![template, [2u8; 32]];
        expected.sort();
        assert_eq!(orphans, expected);
        assert!(s.snapshot_hash(1, 0).unwrap().is_none());
        assert_eq!(s.snapshot_hash(2, 0).unwrap(), Some([1u8; 32]));
    }
}
