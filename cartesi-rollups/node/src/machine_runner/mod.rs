// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod error;

use self::error::Result;
use std::time::Duration;

use crate::engine::{MachineStf, Ruler, Stf, Structure};
use crate::storage::rollups_machine::LOG2_STRIDE;
use crate::storage::{AdvancePlan, Storage};
use crate::sync::ShutdownSignal;

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
    sleep_duration: Duration,
    structure: Structure,
}

impl MachineRunner {
    pub fn new(storage: Storage, sleep_duration: Duration) -> Result<Self> {
        let structure = storage.sling_config()?.structure;
        Ok(Self {
            storage,
            sleep_duration,
            structure,
        })
    }

    pub fn start(&mut self, shutdown: ShutdownSignal) -> Result<()> {
        loop {
            // A failed pass is retried, not fatal: the advance batch
            // is one transaction and replay absorbs re-execution, so
            // a transient failure costs one polling interval, never
            // the validator. Invariant violations are asserts and
            // stay fatal through the panic path.
            if let Err(e) = self.process_rollup() {
                log::warn!("machine advance failed, retrying next tick: {e}");
            }

            // No publishable batch is ready. An open tail shorter
            // than the snapshot gap deliberately waits here.
            if shutdown.wait_timeout(self.sleep_duration) {
                break Ok(());
            }
        }
    }

    fn process_rollup(&mut self) -> Result<()> {
        loop {
            let plan = self.storage.advance_plan()?;
            match plan_action(&plan, self.storage.snapshot_gap_inputs()) {
                PlanAction::Idle => return Ok(()),
                PlanAction::Advance => self.advance(plan)?,
                PlanAction::Roll => {
                    let epoch = plan.epoch;
                    self.storage.roll_epoch()?;
                    log::info!("started new epoch {}", epoch + 1);
                }
            }
        }
    }

    /// Executes exactly the inputs selected by one coherent plan.
    /// The plan is either a full open-epoch gap or a sealed epoch's
    /// final remainder.
    fn advance(&mut self, plan: AdvancePlan) -> Result<()> {
        assert!(!plan.inputs.is_empty());
        let expected = plan.inputs.len();
        let (mut machine, mut batch) = self.storage.begin_planned_advances(&plan)?;

        for input in plan.inputs {
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
            let runs = ruler.collect(self.structure.window_start(window + 1), LOG2_STRIDE)?;
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
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{Input, InputId};

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
            boundary_path: std::path::PathBuf::from("unused-by-plan-action"),
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
}
