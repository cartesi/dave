// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The machine runner's writer role: window roots, snapshot
//! boundaries, epoch roll, and epoch GC. Machine store mechanics and
//! the snapshot rows live in the boundary store (snapshots.rs); this
//! role folds each window's runs into its root row and batches them
//! with the boundaries.
//!
//! The advance path is filesystem-first, database-second: machines
//! land in the content-addressed store before any row references
//! them, and directories are removed only after the commit that
//! unreferenced them. A crash can orphan a directory, never dangle a
//! row. Rows for a whole batch of inputs commit in ONE transaction
//! (cadence = the snapshot gap), so the per-input crash window that
//! produced the verify-on-conflict fix (cff83f7) is structurally
//! gone; the verify remains as a pure nondeterminism tripwire.

use super::convert::u64_to_i64;
use super::error::Result;
use super::open::{create_epoch_dir, snapshots_path};
use super::rollups_machine::RollupsMachine;
use super::snapshots::{
    gc_previous_advances_in, insert_snapshot_in, remove_orphan_dirs,
    sweep_scratch_dirs_at_or_below, sweep_unreferenced_snapshots_in,
};
use super::{Settlement, Storage, rollups_machine};
use crate::engine::Run;

use crate::merkle::Digest;
use cartesi_machine::types::Hash;
use rusqlite::{Transaction, params};
use std::path::{Path, PathBuf};

/// One tick's worth of processed inputs, accumulated in memory and
/// committed atomically. Dropping an uncommitted batch abandons only
/// idempotent content-addressed files and staging clones (swept on
/// drop and at startup) - the database never sees it.
#[derive(Debug)]
pub struct AdvanceBatch {
    epoch: u64,
    /// The boundary the machine currently sits on: the state after
    /// every recorded input, keyed (epoch, boundary_input). Also the
    /// revert restore point - reverts never read the database.
    boundary_input: u64,
    boundary_hash: Hash,
    boundary_path: PathBuf,
    /// The live working clone the machine mutates in place; committed
    /// into the CAS at each accepted input and replaced by a fresh
    /// clone. Always the machine's backing directory.
    working: PathBuf,
    records: Vec<AdvanceRecord>,
}

impl Drop for AdvanceBatch {
    /// The chain's spare clone (or a mid-batch abandonment) is
    /// scratch; best-effort removal here, the startup sweep as the
    /// backstop. Unlinking under a still-open machine is safe: the
    /// mappings hold the files alive until that machine drops.
    fn drop(&mut self) {
        if self.working.exists()
            && let Err(e) = std::fs::remove_dir_all(&self.working)
        {
            log::warn!(
                "working clone `{}` not removed: {e}",
                self.working.display()
            );
        }
    }
}

#[derive(Debug)]
struct AdvanceRecord {
    input_number: u64,
    /// The window's level-0 subtree root, folded from the collect's
    /// runs at record time: the runner's one level-0 artifact
    /// (one-engine.md section 6, as amended). The unfolded runs are
    /// never persisted.
    window_root: Digest,
    /// State after this input, keyed (epoch, input_number + 1). A
    /// reverted input shares its predecessor's snapshot.
    boundary_hash: Hash,
    boundary_path: PathBuf,
}

/// One window's runs folded into its root row's value. Tiling is the
/// engine's geometry contract, so a violation is a panic, not an
/// error.
fn fold_window_root(runs: &[Run]) -> Digest {
    crate::engine::fold_runs(
        runs.iter().map(|run| {
            (
                run.hash,
                u64::try_from(run.repetitions).expect("window runs fit u64"),
            )
        }),
        rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
    )
    .expect("recorded runs tile their window (the collect pads the tail)")
    .root_hash()
}

impl AdvanceBatch {
    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// The committed directory of the state the working clone was
    /// checked out from: the advance stf's revert restore point.
    pub fn boundary_path(&self) -> &Path {
        &self.boundary_path
    }
}

impl Storage {
    /// Opens a batch on a working clone of the newest boundary: the
    /// machine mutates the clone in place (the chain of clones,
    /// docs/plans/snapshots.md), so committed boundaries are never
    /// touched. Restart and tick are the same code path: a crash
    /// re-executes at most one batch of inputs from staging swept
    /// clean.
    pub fn begin_advances(&mut self) -> Result<(RollupsMachine, AdvanceBatch)> {
        let (path, epoch, input, hash) = self.read(super::snapshots::latest_boundary_in)?;
        let working = self.checkout(&path).map_err(anyhow::Error::from)?;
        let machine = RollupsMachine::load_shared(&working, epoch, input)?;

        Ok((
            machine,
            AdvanceBatch {
                epoch,
                boundary_input: input,
                boundary_hash: hash,
                boundary_path: path,
                working,
                records: Vec::new(),
            },
        ))
    }

    /// Records an accepted input: the working clone already holds the
    /// post-input state on disk, so recording is close (flush, unlock),
    /// commit the clone into the content-addressed store, and continue
    /// on a fresh clone of it (filesystem-first; no rows yet). The
    /// window's runs fold into their root here; only the root joins
    /// the batch.
    pub fn record_accepted(
        &mut self,
        batch: &mut AdvanceBatch,
        machine: &mut RollupsMachine,
        runs: &[Run],
    ) -> Result<()> {
        assert!(!runs.is_empty());
        assert_eq!(machine.epoch(), batch.epoch);
        let processed = machine.next_input_index_in_epoch() - 1;
        assert_eq!(
            processed, batch.boundary_input,
            "records must be contiguous"
        );
        let window_root = fold_window_root(runs);

        // The hash first: it brings the clone's on-disk hash sidecars
        // exact, so every later load of this boundary hashes for free.
        // The window's final run must carry it (the fixed point the
        // collect padded with): the recorded material and the boundary
        // row agree by this check at every record.
        let hash = machine.state_hash()?;
        assert_eq!(
            runs.last().expect("nonempty by the assert above").hash,
            Digest::new(hash),
            "the window's final run must carry the machine's boundary state"
        );
        machine.close();
        let working = std::mem::take(&mut batch.working);
        let path = self
            .commit_clone(working, &hash)
            .map_err(anyhow::Error::from)?;
        batch.working = self.checkout(&path).map_err(anyhow::Error::from)?;
        machine.reopen_shared(&batch.working)?;

        batch.records.push(AdvanceRecord {
            input_number: processed,
            window_root,
            boundary_hash: hash,
            boundary_path: path.clone(),
        });
        batch.boundary_input = processed + 1;
        batch.boundary_hash = hash;
        batch.boundary_path = path;

        Ok(())
    }

    /// Records a rejected input: the working clone holds the poisoned
    /// post-input state, so it is discarded and the machine continues
    /// on a fresh clone of the batch boundary (the canonical pre-input
    /// state); the new boundary row will share that snapshot.
    pub fn record_reverted(
        &mut self,
        batch: &mut AdvanceBatch,
        machine: &mut RollupsMachine,
        runs: &[Run],
    ) -> Result<()> {
        assert!(!runs.is_empty());
        assert_eq!(machine.epoch(), batch.epoch);
        let next_input = machine.next_input_index_in_epoch();
        let processed = next_input - 1;
        assert_eq!(
            processed, batch.boundary_input,
            "records must be contiguous"
        );
        let window_root = fold_window_root(runs);
        // A reverted window pads with the restored pre-input state:
        // exactly the boundary this record reuses.
        assert_eq!(
            runs.last().expect("nonempty by the assert above").hash,
            Digest::new(batch.boundary_hash),
            "a reverted window's final run must carry the restored boundary state"
        );

        machine.close();
        self.discard_clone(&batch.working)
            .map_err(anyhow::Error::from)?;
        batch.working = self
            .checkout(&batch.boundary_path)
            .map_err(anyhow::Error::from)?;
        machine.reopen_shared(&batch.working)?;

        batch.records.push(AdvanceRecord {
            input_number: processed,
            window_root,
            boundary_hash: batch.boundary_hash,
            boundary_path: batch.boundary_path.clone(),
        });
        batch.boundary_input = next_input;

        Ok(())
    }

    /// Commits the batch: every window-root quartet row, every
    /// boundary row, and the gap GC, in one transaction. Directories
    /// orphaned by the GC are removed after the commit.
    ///
    /// The window roots flip increment E's "the open regime never
    /// writes sling_nodes" under that note's own frontier rule: a
    /// recorded window lies entirely left of the input frontier, so
    /// its level-0 subtree root is final - one ordinary cache row per
    /// input, absorbed identically on crash replay like every other
    /// row here.
    pub fn commit_advances(&mut self, batch: AdvanceBatch) -> Result<()> {
        if batch.records.is_empty() {
            return Ok(());
        }

        let window_roots: Vec<_> = batch
            .records
            .iter()
            .map(|record| {
                (
                    rollups_machine::window_root_quartet(batch.epoch, record.input_number),
                    record.window_root,
                )
            })
            .collect();

        let gap = self.snapshot_gap_inputs;
        let orphans = self.write(|tx| {
            for record in &batch.records {
                insert_snapshot_in(
                    tx,
                    batch.epoch,
                    record.input_number + 1,
                    &record.boundary_hash,
                    &record.boundary_path,
                )?;
            }
            super::dispute::insert_quartet_nodes_in(tx, &window_roots)?;
            gc_previous_advances_in(tx, batch.epoch, batch.boundary_input, gap)
        })?;
        remove_orphan_dirs(&orphans);

        Ok(())
    }

    /// Closes the epoch: derives the settlement from the recorded
    /// hash runs and the machine's outputs, advances the machine into
    /// the new epoch, stores its boundary (filesystem-first), then
    /// commits settlement + boundary + old-epoch GC in one
    /// transaction.
    pub fn roll_epoch(&mut self) -> Result<()> {
        let mut machine = self.latest_snapshot()?;
        let previous_epoch_number = machine.epoch();

        let computation_hash = self.settlement_root(&mut machine)?;
        let (output_merkle, output_proof) = machine.outputs_proof()?;

        machine.finish_epoch();

        let new_epoch_number = machine.epoch();
        create_epoch_dir(&self.state_dir, new_epoch_number)?;

        let (dest_dir, state_hash) = self
            .store_boundary(&mut machine)
            .map_err(anyhow::Error::from)?;

        // The post-epoch state the settlement protocol claims and
        // stages is exactly the new epoch's initial boundary.
        let settlement = Settlement {
            computation_hash,
            final_state: state_hash,
            output_merkle,
            output_proof,
        };

        let orphans = self.write(|tx| {
            insert_snapshot_in(tx, new_epoch_number, 0, &state_hash, &dest_dir)?;
            insert_settlement_in(tx, &settlement, previous_epoch_number)?;
            if previous_epoch_number >= 1 {
                gc_old_epochs_in(tx, previous_epoch_number - 1)
            } else {
                Ok(Vec::new())
            }
        })?;
        remove_orphan_dirs(&orphans);
        if previous_epoch_number >= 1 {
            sweep_scratch_dirs_at_or_below(&self.state_dir, previous_epoch_number - 1);
        }

        self.log_disk_breakdown(new_epoch_number);

        Ok(())
    }

    /// The settlement's computation hash: node(level-0 root) over the
    /// persisted window roots plus padding math - the same material
    /// and the same fold composition the dispute facade serves, so
    /// the root the node settles on IS the root the hero can defend
    /// from rows. Strict: every recorded window's row was prepaid by
    /// the advance commit; a hole refuses to settle.
    ///
    /// The padding value is the machine's state at the epoch's final
    /// boundary, whose row must agree - a cheap corruption tripwire
    /// at every roll (record time already asserted the final run
    /// against it).
    fn settlement_root(&mut self, machine: &mut RollupsMachine) -> Result<Digest> {
        let epoch = machine.epoch();
        let recorded = machine.next_input_index_in_epoch();
        let boundary = Digest::new(machine.state_hash()?);

        if recorded > 0 {
            // Invariant violations panic: the runner's tick loop
            // retries Err forever, which would silently stall every
            // roll on a corrupt store.
            let row = self.snapshot_hash(epoch, recorded)?.unwrap_or_else(|| {
                panic!(
                    "final boundary row missing for epoch {epoch} at input {recorded}: \
                     corruption or version drift"
                )
            });
            assert_eq!(
                Digest::from_digest(&row).map_err(anyhow::Error::from)?,
                boundary,
                "the final boundary row disagrees with the machine: \
                 the settlement root would diverge from the servable root"
            );
        }

        let mut roots: Vec<(Digest, u64)> = self
            .window_root_range(
                epoch,
                rollups_machine::LOG2_STRIDE,
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
                recorded,
            )?
            .into_iter()
            .map(|root| (root, 1))
            .collect();
        let max_windows = 1u64 << crate::engine::constants::LOG2_INPUT_SPAN_TO_EPOCH;
        if recorded < max_windows {
            let pad_root = crate::engine::fold_runs(
                [(boundary, rollups_machine::STRIDE_COUNT_IN_INPUT)],
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
            )?
            .root_hash();
            roots.push((pad_root, max_windows - recorded));
        }
        Ok(
            crate::engine::fold_runs(roots, crate::engine::constants::LOG2_INPUT_SPAN_TO_EPOCH)?
                .root_hash(),
        )
    }

    /// The disk baseline, logged at every roll (workstream 1 of
    /// docs/plans/node-refactor.md): the snapshot store dominates and
    /// its growth rate is what the COW analysis prices.
    fn log_disk_breakdown(&self, new_epoch_number: u64) {
        let snapshots = dir_size(&snapshots_path(&self.state_dir));
        let db_path = super::open::db_path(&self.state_dir);
        let db = file_size(&db_path);
        let wal = file_size(&db_path.with_extension("sqlite3-wal"));
        let scratch: u64 = (0..=new_epoch_number)
            .map(|epoch| dir_size(&self.state_dir.join(epoch.to_string())))
            .sum();
        const MB: f64 = 1024.0 * 1024.0;
        log::info!(
            "disk after roll to epoch {new_epoch_number}: snapshots {:.1} MB, db {:.1} MB (wal {:.1} MB), epoch scratch {:.1} MB",
            snapshots as f64 / MB,
            db as f64 / MB,
            wal as f64 / MB,
            scratch as f64 / MB,
        );
    }
}

/// Write-once cell semantics: an identical replay absorbs, a
/// disagreeing one is nondeterminism and fails loudly.
pub(super) fn insert_settlement_in(
    tx: &Transaction,
    settlement: &Settlement,
    epoch_number: u64,
) -> Result<()> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO settlement_info
            (epoch_number, computation_hash, output_merkle, output_proof, final_state)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT (epoch_number) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let count = stmt
        .execute(params![
            u64_to_i64(epoch_number),
            settlement.computation_hash.data(),
            &settlement.output_merkle,
            &settlement.output_proof.flatten(),
            &settlement.final_state,
        ])
        .map_err(anyhow::Error::from)?;

    if count == 0 {
        let stored = super::queries::settlement_info_in(tx, epoch_number)?
            .expect("conflicting settlement row exists by the conflict clause");
        // Invariant violation: panic, never a retryable Err (the
        // runner's tick loop would replay the disagreement forever).
        assert_eq!(
            stored, *settlement,
            "settlement for epoch {epoch_number} disagrees with its stored row: \
             nondeterminism or corruption"
        );
    }
    Ok(())
}

/// Prunes everything at or below `max_epoch`: boundary rows and the
/// settled epochs' dispute caches. Safe on sling_nodes because
/// DaveConsensus settles epoch N before sealing N + 1, so rows at or
/// below max_epoch belong to finished tournaments. Returns orphaned
/// directories for post-commit removal.
pub(super) fn gc_old_epochs_in(tx: &Transaction, max_epoch: u64) -> Result<Vec<PathBuf>> {
    tx.execute(
        "DELETE FROM epoch_snapshot_info WHERE epoch_number <= ?1",
        params![u64_to_i64(max_epoch)],
    )
    .map_err(anyhow::Error::from)?;

    tx.execute(
        "DELETE FROM sling_nodes WHERE epoch <= ?1",
        params![u64_to_i64(max_epoch)],
    )
    .map_err(anyhow::Error::from)?;

    // The settled disputes' event logs (fold phase 2): keyed by root
    // tournament, joined through the epochs table's hex encoding.
    tx.execute(
        "DELETE FROM tournament_events WHERE root_tournament IN (
            SELECT root_tournament FROM epochs WHERE epoch_number <= ?1
        )",
        params![u64_to_i64(max_epoch)],
    )
    .map_err(anyhow::Error::from)?;
    tx.execute(
        "DELETE FROM tournament_events_watermark WHERE root_tournament IN (
            SELECT root_tournament FROM epochs WHERE epoch_number <= ?1
        )",
        params![u64_to_i64(max_epoch)],
    )
    .map_err(anyhow::Error::from)?;

    sweep_unreferenced_snapshots_in(tx)
}

/// Best effort: sizes are telemetry, never load-bearing.
fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn dir_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => dir_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::super::sql::test_helper::setup_storage;
    use super::*;
    use crate::merkle::MerkleBuilder;
    use crate::storage::Proof;

    /// A window's runs for tests: arbitrary interior, tail carrying
    /// the machine's boundary state (the record contract), tiling the
    /// window exactly.
    fn window_runs(interior: [u8; 32], boundary: Digest) -> Vec<Run> {
        vec![
            Run {
                hash: Digest::new(interior),
                repetitions: alloy::primitives::U256::from(5),
            },
            Run {
                hash: boundary,
                repetitions: alloy::primitives::U256::from(
                    rollups_machine::STRIDE_COUNT_IN_INPUT - 5,
                ),
            },
        ]
    }

    fn boundary_hash(s: &mut Storage) -> Digest {
        let mut machine = s.latest_snapshot().unwrap();
        Digest::new(machine.state_hash().unwrap())
    }

    fn sparse_window_roots(s: &mut Storage) {
        let rows = [0u64, 2].map(|w| {
            (
                rollups_machine::window_root_quartet(9, w),
                Digest::new([7; 32]),
            )
        });
        s.insert_quartet_nodes(&rows).unwrap();
    }

    // Corruption panics rather than erroring: the tick loops retry
    // errors forever, so only a panic reaches the node's loud exit.
    #[test]
    #[should_panic(expected = "corruption or version drift")]
    fn window_root_range_refuses_count_mismatch() {
        let (_handle, mut s) = setup_storage();
        sparse_window_roots(&mut s);
        let _ = s.window_root_range(
            9,
            rollups_machine::LOG2_STRIDE,
            rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
            3,
        );
    }

    #[test]
    #[should_panic(expected = "corruption or version drift")]
    fn window_root_range_refuses_holes() {
        let (_handle, mut s) = setup_storage();
        sparse_window_roots(&mut s);
        // The right count with a hole in the prefix is loud too.
        let _ = s.window_root_range(
            9,
            rollups_machine::LOG2_STRIDE,
            rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
            2,
        );
    }

    #[test]
    fn settlement_absorbs_identical_refuses_drift() {
        let (_handle, mut s) = setup_storage();
        assert!(s.settlement_info(42).unwrap().is_none());

        let settlement = Settlement {
            computation_hash: [0xAA; 32].into(),
            final_state: [0xDD; 32],
            output_merkle: [0xBB; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        s.write(|tx| insert_settlement_in(tx, &settlement, 42))
            .unwrap();
        assert_eq!(s.settlement_info(42).unwrap().unwrap(), settlement);

        // an identical replay absorbs
        s.write(|tx| insert_settlement_in(tx, &settlement, 42))
            .unwrap();
    }

    #[test]
    #[should_panic(expected = "nondeterminism or corruption")]
    fn settlement_drift_panics() {
        let (_handle, mut s) = setup_storage();
        let settlement = Settlement {
            computation_hash: [0xAA; 32].into(),
            final_state: [0xDD; 32],
            output_merkle: [0xBB; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        s.write(|tx| insert_settlement_in(tx, &settlement, 42))
            .unwrap();

        let mut drifted = settlement.clone();
        drifted.output_merkle = [0xCC; 32];
        let _ = s.write(|tx| insert_settlement_in(tx, &drifted, 42));
    }

    /// Every committed record lands its window-root quartet row:
    /// (epoch, level-0 stride, window height, shift = window), equal
    /// to an independent fold of the record's runs, atomic with the
    /// batch. A replayed batch absorbs identically (determinism).
    #[test]
    fn commit_advances_writes_final_window_roots() {
        let (_handle, mut s) = setup_storage();
        let runs = window_runs([7; 32], boundary_hash(&mut s));

        let (mut machine, mut batch) = s.begin_advances().unwrap();
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &runs).unwrap();
        s.commit_advances(batch).unwrap();

        let expected = crate::engine::fold_runs(
            runs.iter().map(|run| {
                (
                    run.hash,
                    u64::try_from(run.repetitions).expect("window-sized"),
                )
            }),
            rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
        )
        .unwrap()
        .root_hash();
        let quartet = rollups_machine::window_root_quartet(0, 0);
        assert_eq!(s.quartet_node(&quartet).unwrap(), Some(expected));
        assert_eq!(
            s.window_root_count(
                0,
                rollups_machine::LOG2_STRIDE,
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
                1
            )
            .unwrap(),
            1
        );
    }

    /// An empty epoch settles on its initial state: the settlement
    /// root is the padding fold alone, equal to the naive whole-epoch
    /// fold of the boundary hash - pinning the tier composition
    /// against an independent flat fold.
    #[test]
    fn roll_of_an_empty_epoch_settles_on_the_initial_state() {
        let (_handle, mut s) = setup_storage();
        let hash = {
            let mut machine = s.latest_snapshot().unwrap();
            Digest::new(machine.state_hash().unwrap())
        };
        s.roll_epoch().unwrap();

        let expected = {
            let mut builder = MerkleBuilder::default();
            builder.append_repeated(hash, rollups_machine::STRIDE_COUNT_IN_EPOCH);
            builder.build().root_hash()
        };
        assert_eq!(
            s.settlement_info(0).unwrap().unwrap().computation_hash,
            expected
        );
    }

    /// Runs that do not tile their window are a geometry violation
    /// (the collect pads its tail run), so the record panics rather
    /// than inventing a window root.
    #[test]
    #[should_panic(expected = "tile their window")]
    fn record_refuses_non_tiling_runs() {
        let (_handle, mut s) = setup_storage();
        let boundary = boundary_hash(&mut s);
        let short = vec![Run {
            hash: boundary,
            repetitions: alloy::primitives::U256::from(1),
        }];
        let (mut machine, mut batch) = s.begin_advances().unwrap();
        machine.increment_input();
        let _ = s.record_accepted(&mut batch, &mut machine, &short);
    }

    /// A window whose final run does not carry the machine's boundary
    /// state would make the settlement diverge from the servable
    /// root; the record refuses it on the spot.
    #[test]
    #[should_panic(expected = "boundary state")]
    fn record_refuses_runs_disagreeing_with_the_boundary() {
        let (_handle, mut s) = setup_storage();
        let runs = window_runs([7; 32], Digest::new([8; 32]));
        let (mut machine, mut batch) = s.begin_advances().unwrap();
        machine.increment_input();
        let _ = s.record_accepted(&mut batch, &mut machine, &runs);
    }

    /// The batch commit is one transaction: a failure injected at its
    /// last step (the GC) must leave zero torn state, and a plain
    /// retry after healing must succeed - restart IS the loop.
    #[test]
    fn commit_advances_is_atomic_under_injected_failure() {
        let (_handle, mut s) = setup_storage();
        let full_window = vec![Run {
            hash: boundary_hash(&mut s),
            repetitions: alloy::primitives::U256::from(rollups_machine::STRIDE_COUNT_IN_INPUT),
        }];

        let raw = rusqlite::Connection::open(crate::storage::open::db_path(s.state_dir())).unwrap();
        raw.execute_batch(
            "CREATE TRIGGER fail_snapshot_gc BEFORE DELETE ON epoch_snapshot_info
             BEGIN SELECT RAISE(ABORT, 'injected gc failure'); END;",
        )
        .unwrap();

        // Two records: the mid-batch boundary falls to the gap GC,
        // whose delete now aborts the whole commit.
        let (mut machine, mut batch) = s.begin_advances().unwrap();
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &full_window)
            .unwrap();
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &full_window)
            .unwrap();
        assert!(s.commit_advances(batch).is_err());

        assert_eq!(
            s.next_input_id().unwrap().input_index_in_epoch,
            0,
            "the failed commit must not move the resume point"
        );
        assert_eq!(
            s.window_root_count(
                0,
                rollups_machine::LOG2_STRIDE,
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
                2
            )
            .unwrap(),
            0,
            "the failed commit must not leave window-root rows"
        );

        raw.execute_batch("DROP TRIGGER fail_snapshot_gc").unwrap();

        let (mut machine, mut batch) = s.begin_advances().unwrap();
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &full_window)
            .unwrap();
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &full_window)
            .unwrap();
        s.commit_advances(batch).unwrap();
        assert_eq!(s.next_input_id().unwrap().input_index_in_epoch, 2);
    }
}
