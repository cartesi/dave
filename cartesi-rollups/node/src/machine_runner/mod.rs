// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::{Result, ensure};
use std::time::Duration;

use crate::engine::{MachineStf, Ruler, Stf, Structure};
use crate::escalation::Persistence;
use crate::storage::{AdvancePlan, Storage};
use crate::sync::ShutdownSignal;
use log::Level;

/// Snapshot boundaries kept per epoch beyond the start and the
/// latest: every gap-th input. This is the disk-vs-replay knob for
/// dispute positioning; 1 keeps every boundary. It is also the
/// advance-batch size: one commit per gap worth of inputs.
pub const DEFAULT_SNAPSHOT_GAP_INPUTS: u64 = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PlanAction {
    Idle,
    Advance,
    Roll,
}

fn plan_action(plan: &AdvancePlan, gap: u64) -> PlanAction {
    assert!(gap >= 1, "snapshot gap must be positive");
    assert!(
        plan.boundary_input <= plan.input_count,
        "advance plan boundary outruns its input count"
    );
    let available = plan.input_count - plan.boundary_input;
    let scheduled = if plan.sealed || available >= gap {
        available.min(gap)
    } else {
        0
    };
    assert_eq!(
        plan.inputs.len() as u64,
        scheduled,
        "advance plan must carry one contiguous gap at most"
    );

    if plan.sealed {
        if plan.inputs.is_empty() {
            PlanAction::Roll
        } else {
            PlanAction::Advance
        }
    } else if plan.inputs.len() as u64 == gap {
        PlanAction::Advance
    } else {
        PlanAction::Idle
    }
}

pub struct MachineRunner {
    storage: Storage,
    snapshot_gap_inputs: u64,
    sleep_duration: Duration,
    shutdown: ShutdownSignal,
    structure: Structure,
    /// The pinned root stride: each window is sampled at the level-0
    /// leaf spacing of the deployed tournament.
    log2_run_stride: u64,
    /// How long the runner has failed without committing a batch or a roll.
    failing: Persistence,
}

/// The free space an open epoch's batch needs before it starts. Working
/// clones are mapped shared, so a full filesystem kills the node by SIGBUS
/// mid-batch with nothing logged (exit 135). An open epoch's batch runs beside
/// the previous epoch's live dispute and can wait, so below the floor it stops
/// first, with an error the paging rule reports, and leaves the space to the
/// work that carries a clock: a sealed epoch's batches, which its root join
/// waits on while nothing else has a deadline, and the Hero's crossings. The
/// roll maps nothing shared. About one stored machine: a margin, not a bound,
/// since without reflinks a rotation briefly holds a few copies.
const FREE_SPACE_FLOOR: u64 = 1 << 30;

fn ensure_free_space(storage: &Storage) -> Result<()> {
    let free = storage
        .free_bytes()
        .map_err(|e| anyhow::anyhow!("could not read the data directory's free space: {e}"))?;
    ensure!(
        free >= FREE_SPACE_FLOOR,
        "only {} MiB free on the data directory's filesystem, below the {} MiB an open epoch's \
         batch needs: free space there",
        free >> 20,
        FREE_SPACE_FLOOR >> 20
    );
    Ok(())
}

impl MachineRunner {
    pub fn new(
        storage: Storage,
        snapshot_gap_inputs: u64,
        sleep_duration: Duration,
        shutdown: ShutdownSignal,
    ) -> Result<Self> {
        assert!(snapshot_gap_inputs >= 1, "snapshot gap must be positive");
        let config = storage.sling_config()?;
        Ok(Self {
            storage,
            snapshot_gap_inputs,
            sleep_duration,
            shutdown,
            structure: config.structure,
            log2_run_stride: config.geometry.root_stride(),
            failing: Persistence::default(),
        })
    }

    pub fn start(&mut self) -> Result<()> {
        loop {
            // A failed pass is retried, not fatal: the advance batch
            // is one transaction and replay absorbs re-execution, so
            // a transient failure costs one polling interval, never
            // the validator. Invariant violations are asserts and
            // stay fatal through the panic path. One that persists (a
            // full disk, a permission change) stops every settlement and
            // root join, so it pages.
            match self.process_rollup() {
                Ok(()) => self.failing.cleared(),
                Err(e) => match self.failing.failed() {
                    Level::Error => log::error!(
                        "machine advance has failed for {} min: {e:#}; the node is not \
                         computing epochs, so it cannot settle or join their disputes",
                        self.failing.minutes()
                    ),
                    level => log::log!(level, "machine advance failed, retrying next tick: {e:#}"),
                },
            }

            // No publishable batch is ready. An open tail shorter
            // than the snapshot gap deliberately waits here.
            if self.shutdown.wait_timeout(self.sleep_duration) {
                break Ok(());
            }
        }
    }

    /// One tick: publishes every ready batch and roll, then returns. A
    /// stop returns before the next batch or roll, abandoning the batch in
    /// progress.
    pub fn process_rollup(&mut self) -> Result<()> {
        loop {
            // Sealed empty epochs roll without an input, so only this check
            // stops a catch-up through them.
            if self.shutdown.is_requested() {
                return Ok(());
            }
            let plan = self.storage.advance_plan(self.snapshot_gap_inputs)?;
            match plan_action(&plan, self.snapshot_gap_inputs) {
                PlanAction::Idle => return Ok(()),
                PlanAction::Advance => {
                    if !plan.sealed {
                        ensure_free_space(&self.storage)?;
                    }
                    if !self.advance(plan)? {
                        return Ok(());
                    }
                    // Progress within a long catch-up tick restarts the
                    // paging clock, not only a whole successful tick.
                    self.failing.cleared();
                }
                PlanAction::Roll => {
                    let epoch = plan.epoch;
                    self.storage.roll_epoch()?;
                    self.failing.cleared();
                    log::info!("started new epoch {}", epoch + 1);
                }
            }
        }
    }

    /// Executes exactly the inputs selected by one coherent plan.
    /// The plan is either a full open-epoch gap or a sealed epoch's
    /// final remainder. Returns whether it committed: a stop abandons
    /// the batch before its next input, dropping it like any error
    /// return (only transient files go), and a restart replays it.
    fn advance(&mut self, plan: AdvancePlan) -> Result<bool> {
        assert!(!plan.inputs.is_empty());
        let expected = plan.inputs.len();
        let (mut machine, mut batch) = self.storage.begin_planned_advances(&plan)?;

        for input in plan.inputs {
            if self.shutdown.is_requested() {
                log::info!(
                    "stopping: abandoned the batch at input {}:{}",
                    input.id.epoch_number,
                    input.id.input_index_in_epoch
                );
                return Ok(false);
            }
            assert_eq!(
                (machine.epoch(), machine.next_input_index_in_epoch()),
                (input.id.epoch_number, input.id.input_index_in_epoch),
                "advance plan must start at and remain contiguous with the durable cursor"
            );
            log::info!(
                "processing input {}:{}",
                input.id.epoch_number,
                input.id.input_index_in_epoch
            );

            // One window-sized engine collect on the working clone:
            // the same geometry the dispute replays, scheduled
            // forward. Record owns the checkpoint/work-clone swap.
            let window = input.id.input_index_in_epoch;
            let mut stf = MachineStf::over_advancing(
                machine.take_machine(),
                window,
                input.data,
                batch.boundary_path().to_path_buf(),
            );
            assert!(
                stf.yielded()? || stf.terminal()?,
                "the working clone must await input or be terminal"
            );
            let mut ruler = Ruler::new_at(
                stf,
                self.structure,
                window + 1,
                self.structure.window_start(window),
            );
            let runs = ruler.collect(
                self.structure.window_start(window + 1),
                self.log2_run_stride,
            )?;
            let stf = ruler.into_stf();
            let reverted = stf.took_revert();
            machine.put_machine(stf.into_machine());
            machine.increment_input();

            if reverted {
                self.storage
                    .record_reverted(&mut batch, &mut machine, &runs)?;
            } else {
                self.storage
                    .record_accepted(&mut batch, &mut machine, &runs)?;
            }
        }

        assert_eq!(batch.len(), expected);
        drop(machine);
        self.storage.commit_advances(batch)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{Epoch, Input, InputId};
    use alloy::primitives::Address;

    fn plan(boundary: u64, input_count: u64, sealed: bool) -> AdvancePlan {
        let available = input_count - boundary;
        let scheduled = if sealed || available >= 3 {
            available.min(3)
        } else {
            0
        };
        let inputs = (0..scheduled)
            .map(|offset| Input {
                id: InputId {
                    epoch_number: 7,
                    input_index_in_epoch: boundary + offset,
                },
                data: vec![offset as u8],
            })
            .collect();
        AdvancePlan {
            epoch: 7,
            boundary_input: boundary,
            input_count,
            sealed,
            inputs,
            boundary_hash: [0; 32],
        }
    }

    #[test]
    fn gap_three_scheduling_waits_for_open_tail_and_drains_sealed_remainder() {
        assert_eq!(plan_action(&plan(0, 0, false), 3), PlanAction::Idle);
        assert_eq!(plan_action(&plan(0, 2, false), 3), PlanAction::Idle);
        assert_eq!(plan_action(&plan(0, 3, false), 3), PlanAction::Advance);
        assert_eq!(plan_action(&plan(3, 5, false), 3), PlanAction::Idle);

        assert_eq!(plan_action(&plan(3, 5, true), 3), PlanAction::Advance);
        assert_eq!(plan_action(&plan(5, 5, true), 3), PlanAction::Roll);
        assert_eq!(plan_action(&plan(3, 9, true), 3), PlanAction::Advance);
    }

    #[test]
    fn a_stopped_runner_rolls_no_queued_empty_epoch() {
        let (_dir, mut storage) = crate::storage::sql::test_helper::setup_storage();
        let empty: Vec<Epoch> = (0..3)
            .map(|epoch_number| Epoch {
                epoch_number,
                input_index_boundary: 0,
                root_tournament: Address::ZERO,
                block_created_number: 1,
            })
            .collect();
        storage
            .insert_consensus_data(1, [].iter(), empty.iter())
            .unwrap();
        let state_dir = storage.state_dir().to_owned();
        let run = |storage, shutdown| {
            MachineRunner::new(
                storage,
                DEFAULT_SNAPSHOT_GAP_INPUTS,
                Duration::ZERO,
                shutdown,
            )
            .unwrap()
            .process_rollup()
            .unwrap()
        };

        let stopped = ShutdownSignal::default();
        stopped.request();
        run(storage, stopped);
        let mut check = Storage::new(&state_dir).unwrap();
        assert!(
            check.settlement_info(0).unwrap().is_none(),
            "a stopped runner rolled an epoch"
        );

        // Without the stop, the same tick rolls every queued epoch.
        run(Storage::new(&state_dir).unwrap(), ShutdownSignal::default());
        assert!(check.settlement_info(2).unwrap().is_some());
    }

    /// The tick's own check runs before a batch starts, so only the batch's
    /// check bounds a stop to one input's execution; calling `advance` with
    /// a stop already requested is the deterministic way to reach it.
    #[test]
    fn a_stopped_batch_executes_no_further_input() {
        let (_dir, mut storage) = crate::storage::sql::test_helper::setup_storage();
        let inputs: Vec<Input> = (0..2)
            .map(|input_index_in_epoch| Input {
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch,
                },
                data: vec![],
            })
            .collect();
        let sealed = Epoch {
            epoch_number: 0,
            input_index_boundary: 2,
            root_tournament: Address::ZERO,
            block_created_number: 1,
        };
        storage
            .insert_consensus_data(1, inputs.iter(), [&sealed].into_iter())
            .unwrap();
        let state_dir = storage.state_dir().to_owned();
        let plan = storage.advance_plan(DEFAULT_SNAPSHOT_GAP_INPUTS).unwrap();
        assert_eq!(plan.inputs.len(), 2);

        let stopped = ShutdownSignal::default();
        stopped.request();
        let mut runner = MachineRunner::new(
            storage,
            DEFAULT_SNAPSHOT_GAP_INPUTS,
            Duration::ZERO,
            stopped,
        )
        .unwrap();
        assert!(!runner.advance(plan).unwrap(), "a stopped batch committed");
        let mut check = Storage::new(&state_dir).unwrap();
        for input in 1..=2 {
            assert!(check.snapshot_hash(0, input).unwrap().is_none());
        }
    }
}
