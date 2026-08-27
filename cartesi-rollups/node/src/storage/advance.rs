// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The machine runner's writer role: window roots, snapshot
//! boundaries, epoch roll, and epoch GC. Machine store mechanics and
//! the snapshot rows live in the boundary store (snapshots.rs); this
//! role folds each window's runs into its root row and batches them
//! with the boundaries.
//!
//! The advance path keeps rollback checkpoints transient within a
//! batch. Only its final boundary is synced and promoted into the
//! content-addressed store; that boundary and every window root then
//! join the database in one transaction. A crash can orphan a
//! durable directory, never dangle a row, and replays at most one
//! snapshot-gap batch.

use super::convert::{i64_to_u64, u64_to_i64};
use super::error::Result;
use super::open::{create_epoch_dir, snapshots_path};
use super::rollups_machine::RollupsMachine;
use super::snapshots::{
    gc_previous_advances_in, insert_snapshot_in, remove_orphan_dirs,
    sweep_scratch_dirs_at_or_below, sweep_unreferenced_snapshots_in,
};
use super::{Input, Settlement, Storage, rollups_machine};
use crate::engine::Run;

use crate::merkle::Digest;
use alloy::primitives::U256;
use cartesi_machine::{constants::rollup::LOG2_MAX_ADVANCE_STATES_PER_EPOCH, types::Hash};
use rusqlite::{OptionalExtension, Transaction, params};
use std::path::{Path, PathBuf};

/// One coherent view of runner readiness. The durable cursor, input
/// count, seal, and up to one gap of payloads all come from the same
/// read transaction, so an ingest commit cannot mix their vintages.
#[derive(Debug)]
pub(crate) struct AdvancePlan {
    pub(crate) epoch: u64,
    pub(crate) boundary_input: u64,
    pub(crate) input_count: u64,
    pub(crate) sealed: bool,
    pub(crate) inputs: Vec<Input>,
    pub(crate) boundary_path: PathBuf,
    pub(crate) boundary_hash: Hash,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CheckpointOwnership {
    Durable,
    Transient,
}

/// One publication batch, accumulated in memory and committed
/// atomically. Dropping it abandons only transient files; the
/// database never sees a partial batch.
#[derive(Debug)]
pub struct AdvanceBatch {
    epoch: u64,
    /// The state the machine currently sits on and the next input's
    /// revert point. It starts as the durable batch base; accepted
    /// inputs rotate it to a transient closed checkpoint.
    boundary_input: u64,
    boundary_hash: Hash,
    boundary_path: PathBuf,
    boundary_ownership: CheckpointOwnership,
    /// The unique SHARING_ALL clone the machine mutates in place.
    working: PathBuf,
    records: Vec<AdvanceRecord>,
}

impl Drop for AdvanceBatch {
    /// A successfully published checkpoint has its ownership cleared
    /// before the database transaction, so a failed transaction
    /// leaves the durable CAS artifact for retry.
    fn drop(&mut self) {
        if self.working.exists()
            && let Err(e) = std::fs::remove_dir_all(&self.working)
        {
            log::warn!(
                "working clone `{}` not removed: {e}",
                self.working.display()
            );
        }
        if self.boundary_ownership == CheckpointOwnership::Transient
            && self.boundary_path.exists()
            && let Err(e) = std::fs::remove_dir_all(&self.boundary_path)
        {
            log::warn!(
                "transient checkpoint `{}` not removed: {e}",
                self.boundary_path.display()
            );
        }
    }
}

#[derive(Debug)]
struct AdvanceRecord {
    input_number: u64,
    /// The window's level-0 subtree root, folded from the collect's
    /// runs at record time: the runner's only level-0 artifact. The
    /// unfolded runs are never persisted.
    window_root: Digest,
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

    /// The closed checkpoint the advance stf reloads on rejection.
    /// It may be transient inside the batch.
    pub fn boundary_path(&self) -> &Path {
        &self.boundary_path
    }
}

fn input_count_in(tx: &Transaction, epoch: u64) -> Result<u64> {
    let count: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM inputs WHERE epoch_number = ?1",
            [u64_to_i64(epoch)],
            |row| row.get(0),
        )
        .map_err(anyhow::Error::from)?;
    Ok(i64_to_u64(count))
}

fn epoch_is_sealed_in(tx: &Transaction, epoch: u64) -> Result<bool> {
    Ok(tx
        .query_row(
            "SELECT 1 FROM epochs WHERE epoch_number = ?1",
            [u64_to_i64(epoch)],
            |_| Ok(()),
        )
        .optional()
        .map_err(anyhow::Error::from)?
        .is_some())
}

fn assert_complete_window_prefix_in(tx: &Transaction, epoch: u64, input_count: u64) -> Result<()> {
    let mut stmt = tx
        .prepare_cached(
            "SELECT shift FROM sling_nodes
             WHERE epoch = ?1 AND log2_stride = ?2 AND height = ?3 AND shift < ?4
             ORDER BY shift ASC",
        )
        .map_err(anyhow::Error::from)?;
    let rows = stmt
        .query_map(
            params![
                u64_to_i64(epoch),
                u64_to_i64(rollups_machine::LOG2_STRIDE),
                u64_to_i64(rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT),
                U256::from(input_count).to_be_bytes::<32>()
            ],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .map_err(anyhow::Error::from)?;
    let shifts = rows
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(anyhow::Error::from)?;

    assert_eq!(
        shifts.len() as u64,
        input_count,
        "epoch {epoch} has {} window roots at roll, expected {input_count}",
        shifts.len()
    );
    for (window, shift) in shifts.into_iter().enumerate() {
        assert_eq!(
            shift,
            U256::from(window).to_be_bytes::<32>(),
            "epoch {epoch}'s window-root prefix has a hole at {window}"
        );
    }
    Ok(())
}

/// The roll's hard guard, suitable both before expensive machine work
/// and inside the settlement transaction. It speaks only durable
/// state: exact sealed epoch, final boundary, and complete root prefix.
fn roll_ready_in(tx: &Transaction) -> Result<(u64, u64)> {
    let (_, epoch, boundary_input, _) = super::snapshots::latest_boundary_in(tx)?;
    assert!(
        epoch_is_sealed_in(tx, epoch)?,
        "refusing to roll open epoch {epoch}"
    );
    let input_count = input_count_in(tx, epoch)?;
    assert_eq!(
        boundary_input, input_count,
        "refusing to roll epoch {epoch}: durable boundary {boundary_input}, input count {input_count}"
    );
    assert_complete_window_prefix_in(tx, epoch, input_count)?;
    Ok((epoch, boundary_input))
}

impl Storage {
    /// Plans at most one publication batch from one SQLite snapshot.
    /// Open short tails return no payloads, avoiding copies on every
    /// poll; a sealed tail is materialized so it can publish before
    /// the roll.
    pub(crate) fn advance_plan(&mut self) -> Result<AdvancePlan> {
        let gap = self.snapshot_gap_inputs;
        let plan = self.read(|tx| {
            let (boundary_path, epoch, boundary_input, boundary_hash) =
                super::snapshots::latest_boundary_in(tx)?;
            let input_count = input_count_in(tx, epoch)?;
            assert!(
                boundary_input <= input_count,
                "durable boundary {boundary_input} outruns epoch {epoch}'s {input_count} inputs"
            );
            let sealed = epoch_is_sealed_in(tx, epoch)?;
            let available = input_count - boundary_input;
            let planned = if sealed || available >= gap {
                available.min(gap)
            } else {
                0
            };

            let mut stmt = tx
                .prepare_cached(
                    "SELECT input_index_in_epoch, input FROM inputs
                     WHERE epoch_number = ?1 AND input_index_in_epoch >= ?2
                     ORDER BY input_index_in_epoch ASC
                     LIMIT ?3",
                )
                .map_err(anyhow::Error::from)?;
            let rows = stmt
                .query_map(
                    params![
                        u64_to_i64(epoch),
                        u64_to_i64(boundary_input),
                        u64_to_i64(planned)
                    ],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?)),
                )
                .map_err(anyhow::Error::from)?;
            let rows = rows
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)?;
            assert_eq!(
                rows.len() as u64,
                planned,
                "epoch {epoch}'s input prefix is not contiguous from boundary {boundary_input}"
            );

            let inputs = rows
                .into_iter()
                .enumerate()
                .map(|(offset, (index, data))| {
                    let index = i64_to_u64(index);
                    assert_eq!(
                        index,
                        boundary_input + offset as u64,
                        "epoch {epoch}'s input prefix has a hole"
                    );
                    Input {
                        id: super::InputId {
                            epoch_number: epoch,
                            input_index_in_epoch: index,
                        },
                        data,
                    }
                })
                .collect();

            Ok(AdvancePlan {
                epoch,
                boundary_input,
                input_count,
                sealed,
                inputs,
                boundary_path,
                boundary_hash,
            })
        })?;
        // This runs before the caller considers readiness, so an
        // idle open tail cannot hide a dangling durable cursor behind
        // the runner's polling loop.
        super::snapshots::assert_runner_boundary_dir(
            &plan.boundary_path,
            plan.epoch,
            plan.boundary_input,
        );
        Ok(plan)
    }

    /// Opens a batch on a working clone of the newest boundary: the
    /// machine mutates the clone in place, leaving committed
    /// boundaries untouched. Restart and tick are the same code path:
    /// a crash re-executes at most one batch of inputs from staging
    /// swept clean.
    pub fn begin_advances(&mut self) -> Result<(RollupsMachine, AdvanceBatch)> {
        let (path, epoch, input, hash) = self.read(super::snapshots::latest_boundary_in)?;
        self.begin_advances_at(path, epoch, input, hash)
    }

    /// Opens exactly the durable boundary and payload vintage selected
    /// by the planner. A later ingest commit may add inputs, but it
    /// cannot silently change this batch's starting point.
    pub(crate) fn begin_planned_advances(
        &self,
        plan: &AdvancePlan,
    ) -> Result<(RollupsMachine, AdvanceBatch)> {
        self.begin_advances_at(
            plan.boundary_path.clone(),
            plan.epoch,
            plan.boundary_input,
            plan.boundary_hash,
        )
    }

    fn begin_advances_at(
        &self,
        path: PathBuf,
        epoch: u64,
        input: u64,
        hash: Hash,
    ) -> Result<(RollupsMachine, AdvanceBatch)> {
        super::snapshots::assert_runner_boundary_dir(&path, epoch, input);
        let working = match self.checkout(&path) {
            Ok(working) => working,
            Err(error) => {
                // Promote a source that disappeared during checkout
                // to the fatal invariant; other clone errors retry.
                super::snapshots::assert_runner_boundary_dir(&path, epoch, input);
                return Err(anyhow::Error::from(error).into());
            }
        };
        // Construct the cleanup guard before loading. On a load or
        // root-verification failure, the machine drops before the
        // batch removes its working clone.
        let batch = AdvanceBatch {
            epoch,
            boundary_input: input,
            boundary_hash: hash,
            boundary_path: path.clone(),
            boundary_ownership: CheckpointOwnership::Durable,
            working,
            records: Vec::new(),
        };
        let mut machine = match RollupsMachine::load_shared(&batch.working, epoch, input) {
            Ok(machine) => machine,
            Err(error) => {
                super::snapshots::assert_runner_boundary_dir(&path, epoch, input);
                return Err(error.into());
            }
        };
        super::snapshots::assert_runner_boundary_root(&mut machine, &hash, &path, epoch, input);

        Ok((machine, batch))
    }

    /// Records an accepted input: close the mutated working clone,
    /// make it the batch's transient rollback checkpoint, and
    /// continue on a fresh SHARING_ALL clone. No CAS path or database
    /// row is created until the batch boundary is published.
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

        // The hash first brings the clone's on-disk sidecars exact.
        // The final run must carry the same fixed point.
        let hash = machine.state_hash()?;
        assert_eq!(
            runs.last().expect("nonempty by the assert above").hash,
            Digest::new(hash),
            "the window's final run must carry the machine's boundary state"
        );
        machine.close();

        let checkpoint = batch.working.clone();
        let next_working = self.checkout(&checkpoint).map_err(anyhow::Error::from)?;
        if let Err(error) = machine.reopen_shared(&next_working) {
            let _ = self.discard_clone(&next_working);
            return Err(anyhow::Error::from(error).into());
        }

        let old_checkpoint = batch.boundary_path.clone();
        let old_ownership = batch.boundary_ownership;
        batch.working = next_working;
        batch.boundary_path = checkpoint;
        batch.boundary_ownership = CheckpointOwnership::Transient;
        if old_ownership == CheckpointOwnership::Transient
            && let Err(error) = self.discard_clone(&old_checkpoint)
        {
            log::warn!(
                "superseded transient checkpoint `{}` not removed: {error}",
                old_checkpoint.display()
            );
        }

        batch.records.push(AdvanceRecord {
            input_number: processed,
            window_root,
        });
        batch.boundary_input = processed + 1;
        batch.boundary_hash = hash;

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
        let next_working = self
            .checkout(&batch.boundary_path)
            .map_err(anyhow::Error::from)?;
        if let Err(error) = machine.reopen_shared(&next_working) {
            let _ = self.discard_clone(&next_working);
            return Err(anyhow::Error::from(error).into());
        }
        batch.working = next_working;

        batch.records.push(AdvanceRecord {
            input_number: processed,
            window_root,
        });
        batch.boundary_input = next_input;

        Ok(())
    }

    /// Durably publishes only the batch's final boundary, then commits
    /// that one row, every window root, and gap GC in one transaction.
    /// Clearing transient ownership immediately after CAS publication
    /// preserves the artifact across a database failure for retry.
    ///
    /// A recorded window lies entirely left of the input frontier, so
    /// its level-0 subtree root is final: one ordinary cache row per
    /// input, absorbed identically on crash replay like every other
    /// row here.
    pub fn commit_advances(&mut self, mut batch: AdvanceBatch) -> Result<()> {
        if batch.records.is_empty() {
            return Ok(());
        }

        if batch.boundary_ownership == CheckpointOwnership::Transient {
            let dest = self
                .commit_clone(batch.boundary_path.clone(), &batch.boundary_hash)
                .map_err(anyhow::Error::from)?;
            batch.boundary_path = dest;
            batch.boundary_ownership = CheckpointOwnership::Durable;
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
            insert_snapshot_in(
                tx,
                batch.epoch,
                batch.boundary_input,
                &batch.boundary_hash,
                &batch.boundary_path,
            )?;
            super::dispute::insert_quartet_nodes_in(tx, &window_roots)?;
            gc_previous_advances_in(tx, batch.epoch, batch.boundary_input, gap)
        })?;
        remove_orphan_dirs(&orphans);

        Ok(())
    }

    /// Closes an exactly sealed and fully published epoch. The hard
    /// readiness guard runs before machine work and again inside the
    /// settlement transaction, so an ingest commit cannot make a
    /// stale plan roll past an input.
    pub fn roll_epoch(&mut self) -> Result<()> {
        let expected_position = self.read(roll_ready_in)?;
        let mut machine = self.latest_snapshot()?;
        let previous_epoch_number = machine.epoch();
        let recorded = machine.next_input_index_in_epoch();
        assert_eq!(
            (previous_epoch_number, recorded),
            expected_position,
            "roll machine disagrees with its durable boundary"
        );

        let computation_hash = self.settlement_root(&mut machine)?;
        let (proof_root, machine_validity_proof) = machine.machine_validity_proof()?;

        machine.finish_epoch();

        let new_epoch_number = machine.epoch();
        create_epoch_dir(&self.state_dir, new_epoch_number)?;

        let (dest_dir, state_hash) = self
            .store_boundary(&mut machine)
            .map_err(anyhow::Error::from)?;

        assert_eq!(
            state_hash, proof_root,
            "stored post-epoch boundary differs from the machine validity proof root"
        );

        // The post-epoch state the settlement protocol claims and
        // stages is exactly the new epoch's initial boundary.
        let settlement = Settlement {
            computation_hash,
            final_state: state_hash,
            machine_validity_proof,
        };

        let orphans = self.write(|tx| {
            assert_eq!(
                roll_ready_in(tx)?,
                (previous_epoch_number, recorded),
                "roll readiness changed before settlement commit"
            );
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
        let max_windows = 1u64 << LOG2_MAX_ADVANCE_STATES_PER_EPOCH;
        if recorded < max_windows {
            let pad_root = crate::engine::fold_runs(
                [(boundary, rollups_machine::STRIDE_COUNT_IN_INPUT)],
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
            )?
            .root_hash();
            roots.push((pad_root, max_windows - recorded));
        }
        Ok(crate::engine::fold_runs(roots, LOG2_MAX_ADVANCE_STATES_PER_EPOCH)?.root_hash())
    }

    /// The disk baseline, logged at every roll: the snapshot store
    /// dominates and its growth rate is what the COW analysis prices.
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
    super::rollups_machine::validate_machine_validity_proof(
        settlement.final_state,
        &settlement.machine_validity_proof,
    )
    .unwrap_or_else(|error| {
        panic!("refusing invalid settlement proof for epoch {epoch_number}: {error:#}")
    });

    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO settlement_info
            (epoch_number, computation_hash, final_state,
             iflags_y_data_block, iflags_y_siblings,
             htif_tohost_data_block, htif_tohost_siblings,
             tx_buffer_data_block, tx_buffer_siblings)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT (epoch_number) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let proof = &settlement.machine_validity_proof;

    let count = stmt
        .execute(params![
            u64_to_i64(epoch_number),
            settlement.computation_hash.data(),
            &settlement.final_state,
            &proof.iflags_y_proof.data_block,
            &proof.iflags_y_proof.siblings.flatten(),
            &proof.htif_tohost_proof.data_block,
            &proof.htif_tohost_proof.siblings.flatten(),
            &proof.tx_buffer_proof.data_block,
            &proof.tx_buffer_proof.siblings.flatten(),
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
    use super::super::queries::{setup_settlement_storage, test_settlement};
    use super::super::sql::test_helper::setup_storage;
    use super::*;
    use crate::merkle::MerkleBuilder;
    use crate::storage::Epoch;
    use alloy::primitives::Address;

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

    fn flat_window(boundary: Digest) -> Vec<Run> {
        vec![Run {
            hash: boundary,
            repetitions: U256::from(rollups_machine::STRIDE_COUNT_IN_INPUT),
        }]
    }

    fn mutate(machine: &mut RollupsMachine, offset: u64, value: u8) -> Digest {
        let mut inner = machine.take_machine();
        inner
            .write_memory(cartesi_machine::constants::ar::RAM_START + offset, &[value])
            .unwrap();
        machine.put_machine(inner);
        Digest::new(machine.state_hash().unwrap())
    }

    fn append_inputs(s: &mut Storage, start: u64, count: u64) {
        let inputs: Vec<_> = (start..start + count)
            .map(|index| Input {
                id: super::super::InputId {
                    epoch_number: 0,
                    input_index_in_epoch: index,
                },
                data: vec![index as u8],
            })
            .collect();
        s.insert_consensus_data(1, inputs.iter(), [].iter())
            .unwrap();
    }

    fn seal_epoch_zero(s: &mut Storage) {
        let epoch = Epoch {
            epoch_number: 0,
            input_index_boundary: 0,
            root_tournament: Address::ZERO,
            block_created_number: 1,
        };
        s.insert_consensus_data(1, [].iter(), [&epoch].into_iter())
            .unwrap();
    }

    fn record_mutated_batch(s: &mut Storage, count: u64) -> (AdvanceBatch, Digest) {
        let (mut machine, mut batch) = s.begin_advances().unwrap();
        let mut final_hash = Digest::new(machine.state_hash().unwrap());
        for offset in 0..count {
            final_hash = mutate(&mut machine, offset, 0x40 + offset as u8);
            machine.increment_input();
            s.record_accepted(&mut batch, &mut machine, &flat_window(final_hash))
                .unwrap();
        }
        drop(machine);
        (batch, final_hash)
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

    /// Missing intermediate snapshots only lengthen dispute replay,
    /// but the newest boundary is the runner's durable cursor. The
    /// cursor is checked even when the open epoch has no publishable
    /// tail and would otherwise idle.
    #[test]
    #[should_panic(expected = "durable runner boundary vanished: epoch 0, input 1")]
    fn missing_latest_boundary_is_strict_while_dispute_floor_falls_back() {
        let (_handle, mut s) = setup_storage();
        let epoch_start = s.snapshot_dir(0, 0).unwrap().unwrap();
        append_inputs(&mut s, 0, 1);

        let latest = tempfile::tempdir().unwrap();
        s.insert_boundary(0, 1, &[0xA5; 32], latest.path()).unwrap();
        drop(latest);

        assert_eq!(
            s.nearest_boundary_at_or_before(0, 1).unwrap(),
            (crate::engine::InputBoundary(0), epoch_start)
        );

        // Boundary equals input count in an open epoch: this plan
        // would be idle if the durable cursor still existed.
        let _ = s.advance_plan();
    }

    /// A plan only pins database identity. The loader checks the
    /// referenced directory again before opening its working clone.
    #[test]
    #[should_panic(expected = "durable runner boundary vanished: epoch 0, input 0")]
    fn planned_boundary_that_vanishes_before_load_is_fatal() {
        let (_handle, mut s) = setup_storage();
        let plan = s.advance_plan().unwrap();
        assert!(plan.inputs.is_empty());
        assert!(
            plan.boundary_path
                .starts_with(snapshots_path(s.state_dir()))
        );

        std::fs::remove_dir_all(&plan.boundary_path).unwrap();
        let _ = s.begin_planned_advances(&plan);
    }

    /// A loadable directory under the wrong row hash is corruption,
    /// not retryable machine work. The cleanup guard must also remove
    /// the working clone created before verification.
    #[test]
    fn loaded_boundary_root_mismatch_is_fatal_and_cleans_working_clone() {
        let (_handle, mut s) = setup_storage();
        let path = s.snapshot_dir(0, 0).unwrap().unwrap();
        let wrong = [0xA5; 32];
        assert_ne!(s.snapshot_hash(0, 0).unwrap().unwrap(), wrong);
        s.insert_boundary(42, 0, &wrong, &path).unwrap();
        let plan = s.advance_plan().unwrap();

        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = s.begin_planned_advances(&plan);
        }))
        .expect_err("row/root mismatch must panic");
        let message = panic
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| panic.downcast_ref::<&str>().copied())
            .unwrap_or("non-string panic");
        assert!(message.contains("durable runner boundary root mismatch: epoch 42, input 0"));
        assert!(message.contains(&path.display().to_string()));

        let leaked_working = std::fs::read_dir(snapshots_path(s.state_dir()))
            .unwrap()
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().starts_with(".work-"));
        assert!(!leaked_working, "working clone leaked after panic");
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
        let (_handle, mut s) = setup_settlement_storage();
        assert!(s.settlement_info(42).unwrap().is_none());

        let settlement = test_settlement();
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
        let (_handle, mut s) = setup_settlement_storage();
        let settlement = test_settlement();
        s.write(|tx| insert_settlement_in(tx, &settlement, 42))
            .unwrap();

        let mut drifted = settlement.clone();
        drifted.computation_hash = [0xCC; 32].into();
        let _ = s.write(|tx| insert_settlement_in(tx, &drifted, 42));
    }

    #[test]
    fn invalid_settlement_proof_is_not_persisted() {
        let (_handle, mut s) = setup_settlement_storage();
        let mut settlement = test_settlement();
        settlement
            .machine_validity_proof
            .htif_tohost_proof
            .data_block[0] ^= 1;

        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = s.write(|tx| insert_settlement_in(tx, &settlement, 42));
        }))
        .expect_err("invalid settlement proof must panic");
        let message = panic
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| panic.downcast_ref::<&str>().copied())
            .unwrap_or("non-string panic");
        assert!(message.contains("refusing invalid settlement proof"));
        assert!(s.settlement_info(42).unwrap().is_none());
    }

    #[test]
    fn gap_three_plan_waits_open_and_materializes_the_sealed_tail() {
        let (_handle, mut s) = setup_storage();
        s.set_snapshot_gap_inputs(3);

        let plan = s.advance_plan().unwrap();
        assert_eq!((plan.boundary_input, plan.input_count), (0, 0));
        assert!(!plan.sealed);
        assert!(plan.inputs.is_empty());

        append_inputs(&mut s, 0, 2);
        let plan = s.advance_plan().unwrap();
        assert_eq!(plan.input_count, 2);
        assert!(plan.inputs.is_empty(), "an open short tail must idle");

        append_inputs(&mut s, 2, 1);
        let plan = s.advance_plan().unwrap();
        assert_eq!(
            plan.inputs
                .iter()
                .map(|input| input.id.input_index_in_epoch)
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );

        let start_path = s.snapshot_dir(0, 0).unwrap().unwrap();
        let start_hash = s.snapshot_hash(0, 0).unwrap().unwrap();
        s.insert_boundary(0, 3, &start_hash, &start_path).unwrap();
        append_inputs(&mut s, 3, 1);
        let plan = s.advance_plan().unwrap();
        assert_eq!((plan.boundary_input, plan.input_count), (3, 4));
        assert!(plan.inputs.is_empty());

        // The last input and seal arrive atomically. The plan must
        // observe both from that same transaction and drain the
        // complete sealed remainder.
        let last = Input {
            id: super::super::InputId {
                epoch_number: 0,
                input_index_in_epoch: 4,
            },
            data: vec![4],
        };
        let epoch = Epoch {
            epoch_number: 0,
            input_index_boundary: 0,
            root_tournament: Address::ZERO,
            block_created_number: 1,
        };
        s.insert_consensus_data(2, [&last].into_iter(), [&epoch].into_iter())
            .unwrap();
        let plan = s.advance_plan().unwrap();
        assert!(plan.sealed);
        assert_eq!(
            plan.inputs
                .iter()
                .map(|input| input.id.input_index_in_epoch)
                .collect::<Vec<_>>(),
            vec![3, 4]
        );

        s.insert_boundary(0, 5, &start_hash, &start_path).unwrap();
        let plan = s.advance_plan().unwrap();
        assert!(plan.sealed);
        assert_eq!((plan.boundary_input, plan.input_count), (5, 5));
        assert!(plan.inputs.is_empty());
    }

    #[test]
    fn gap_three_mixed_accept_reject_publishes_only_final_boundary() {
        let (_handle, mut s) = setup_storage();
        s.set_snapshot_gap_inputs(3);
        append_inputs(&mut s, 0, 3);

        let (mut machine, mut batch) = s.begin_advances().unwrap();
        let accepted_0 = mutate(&mut machine, 0, 0x11);
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &flat_window(accepted_0))
            .unwrap();
        let first_checkpoint = batch.boundary_path.clone();
        assert_eq!(batch.boundary_ownership, CheckpointOwnership::Transient);

        let _poisoned = mutate(&mut machine, 1, 0xEE);
        machine.increment_input();
        s.record_reverted(&mut batch, &mut machine, &flat_window(accepted_0))
            .unwrap();
        assert_eq!(Digest::new(machine.state_hash().unwrap()), accepted_0);
        assert_eq!(batch.boundary_path, first_checkpoint);

        let accepted_2 = mutate(&mut machine, 2, 0x22);
        machine.increment_input();
        s.record_accepted(&mut batch, &mut machine, &flat_window(accepted_2))
            .unwrap();
        assert!(
            !first_checkpoint.exists(),
            "the superseded transient checkpoint should be reclaimed"
        );
        assert_eq!(
            s.epoch_snapshots(0)
                .unwrap()
                .into_iter()
                .map(|(boundary, _)| boundary.0)
                .collect::<Vec<_>>(),
            vec![0],
            "no intermediate batch boundary may enter the database"
        );

        drop(machine);
        s.commit_advances(batch).unwrap();
        assert_eq!(
            s.epoch_snapshots(0)
                .unwrap()
                .into_iter()
                .map(|(boundary, _)| boundary.0)
                .collect::<Vec<_>>(),
            vec![0, 3]
        );
        assert_eq!(s.snapshot_hash(0, 3).unwrap(), Some(accepted_2.data()));
        assert_eq!(
            s.window_root_count(
                0,
                rollups_machine::LOG2_STRIDE,
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
                3
            )
            .unwrap(),
            3
        );
    }

    #[test]
    fn gap_three_all_rejected_reuses_the_durable_checkpoint() {
        let (_handle, mut s) = setup_storage();
        s.set_snapshot_gap_inputs(3);
        append_inputs(&mut s, 0, 3);
        let start_path = s.snapshot_dir(0, 0).unwrap().unwrap();
        let start_hash = s.snapshot_hash(0, 0).unwrap().unwrap();

        let (mut machine, mut batch) = s.begin_advances().unwrap();
        for offset in 0..3 {
            let _poisoned = mutate(&mut machine, offset, 0x80 + offset as u8);
            machine.increment_input();
            s.record_reverted(
                &mut batch,
                &mut machine,
                &flat_window(Digest::new(start_hash)),
            )
            .unwrap();
        }
        assert_eq!(batch.boundary_ownership, CheckpointOwnership::Durable);
        assert_eq!(batch.boundary_path, start_path);

        drop(machine);
        s.commit_advances(batch).unwrap();
        let snapshots = s.epoch_snapshots(0).unwrap();
        assert_eq!(
            snapshots
                .iter()
                .map(|(boundary, _)| boundary.0)
                .collect::<Vec<_>>(),
            vec![0, 3]
        );
        assert_eq!(snapshots[0].1, snapshots[1].1);
        assert_eq!(s.snapshot_hash(0, 3).unwrap(), Some(start_hash));

        seal_epoch_zero(&mut s);
        s.roll_epoch().unwrap();
        assert_eq!(s.next_input_id().unwrap().epoch_number, 1);
        assert!(s.settlement_info(0).unwrap().is_some());
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
        seal_epoch_zero(&mut s);
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

    #[test]
    #[should_panic(expected = "refusing to roll open epoch")]
    fn roll_refuses_an_open_epoch() {
        let (_handle, mut s) = setup_storage();
        let _ = s.roll_epoch();
    }

    #[test]
    #[should_panic(expected = "durable boundary 0, input count 1")]
    fn roll_refuses_a_sealed_epoch_with_unpublished_inputs() {
        let (_handle, mut s) = setup_storage();
        append_inputs(&mut s, 0, 1);
        seal_epoch_zero(&mut s);

        let _ = s.roll_epoch();
    }

    #[test]
    #[should_panic(expected = "window roots at roll")]
    fn roll_refuses_a_missing_window_root_prefix() {
        let (_handle, mut s) = setup_storage();
        append_inputs(&mut s, 0, 1);
        seal_epoch_zero(&mut s);
        let path = s.snapshot_dir(0, 0).unwrap().unwrap();
        let hash = s.snapshot_hash(0, 0).unwrap().unwrap();
        s.insert_boundary(0, 1, &hash, &path).unwrap();

        let _ = s.roll_epoch();
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

    /// CAS publication precedes the database transaction. A failure
    /// after rename leaves the durable artifact but no partial rows;
    /// replay re-derives the same root, adopts that CAS path, and
    /// commits the whole batch.
    #[test]
    fn commit_advances_is_atomic_under_injected_failure() {
        let (_handle, mut s) = setup_storage();
        s.set_snapshot_gap_inputs(3);
        append_inputs(&mut s, 0, 3);

        let raw = rusqlite::Connection::open(crate::storage::open::db_path(s.state_dir())).unwrap();
        raw.execute_batch(include_str!(
            "sql/testdata/inject_batch_boundary_failure.sql"
        ))
        .unwrap();

        let (batch, final_hash) = record_mutated_batch(&mut s, 3);
        let cas_path =
            snapshots_path(s.state_dir()).join(format!("0x{}", hex::encode(final_hash.data())));
        assert!(!cas_path.exists());
        assert!(s.commit_advances(batch).is_err());
        assert!(
            cas_path.exists(),
            "the synced and renamed CAS artifact survives the database failure"
        );

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
                3
            )
            .unwrap(),
            0,
            "the failed commit must not leave window-root rows"
        );

        raw.execute_batch(include_str!(
            "sql/testdata/remove_batch_boundary_failure.sql"
        ))
        .unwrap();

        let (batch, replay_hash) = record_mutated_batch(&mut s, 3);
        assert_eq!(replay_hash, final_hash);
        s.commit_advances(batch).unwrap();
        assert_eq!(s.next_input_id().unwrap().input_index_in_epoch, 3);
        assert_eq!(s.snapshot_hash(0, 3).unwrap(), Some(final_hash.data()));
        assert!(cas_path.exists());
    }
}
