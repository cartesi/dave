// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod error;

use self::error::Result;
use std::time::Duration;

use crate::engine::{MachineStf, Ruler, Stf, Structure};
use crate::storage::rollups_machine::LOG2_STRIDE;
use crate::storage::{InputId, Storage};
use crate::sync::ShutdownSignal;

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

            // all inputs have been processed up to this point,
            // sleep and come back later
            if shutdown.wait_timeout(self.sleep_duration) {
                break Ok(());
            }
        }
    }

    fn process_rollup(&mut self) -> Result<()> {
        // process all inputs that are currently availalble
        loop {
            self.catch_up()?;

            let current_machine_epoch = self.storage.next_input_id()?.epoch_number;
            let latest_blockchain_epoch = self.storage.epoch_count()?;

            if current_machine_epoch == latest_blockchain_epoch {
                // all current inputs processed in current epoch, which is still open.
                // sleep and come back later.
                break Ok(());
            } else {
                // epoch is finished, all inputs processed
                assert!(current_machine_epoch < latest_blockchain_epoch);
                self.storage.roll_epoch()?;
                log::info!("started new epoch {}", current_machine_epoch + 1);
            }
        }
    }

    /// Processes available inputs in batches of the snapshot gap:
    /// each pass reloads the machine from the newest boundary,
    /// records up to a batch of inputs, and commits their rows in one
    /// transaction. Restart and tick are the same code path; a crash
    /// re-executes at most one batch.
    fn catch_up(&mut self) -> Result<()> {
        let batch_size = self.storage.snapshot_gap_inputs();

        loop {
            let (mut machine, mut batch) = self.storage.begin_advances()?;

            while (batch.len() as u64) < batch_size {
                let input_id = InputId {
                    epoch_number: machine.epoch(),
                    input_index_in_epoch: machine.next_input_index_in_epoch(),
                };
                let Some(input) = self.storage.input(&input_id)? else {
                    break;
                };

                log::info!(
                    "processing input {}:{}",
                    input.id.epoch_number,
                    input.id.input_index_in_epoch
                );

                // One window-sized engine collect on the working
                // clone: the same geometry the dispute replays,
                // scheduled forward. The machine moves out for the
                // window and back for the record verbs, which own
                // the clone swap either way.
                let window = input_id.input_index_in_epoch;
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

            let exhausted = (batch.len() as u64) < batch_size;
            self.storage.commit_advances(batch)?;

            if exhausted {
                break Ok(());
            }
        }
    }
}
