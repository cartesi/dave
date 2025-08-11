// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod error;

use error::Result;
use std::{ops::ControlFlow, time::Duration};

use cartesi_machine::types::cmio::ManualReason;
use rollups_state_manager::{InputId, StateManager, rollups_machine::RollupsMachine, sync::Watch};
pub struct MachineRunner<SM: StateManager> {
    state_manager: SM,
    sleep_duration: Duration,
}

impl<SM: StateManager + std::fmt::Debug> MachineRunner<SM> {
    pub fn new(state_manager: SM, sleep_duration: Duration) -> Result<Self> {
        Ok(Self {
            state_manager,
            sleep_duration,
        })
    }

    pub fn start(&mut self, watch: Watch) -> Result<()> {
        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            if matches!(watch.wait(self.sleep_duration), ControlFlow::Break(_)) {
                break Ok(());
            }
        }
    }

    fn process_rollup(&mut self) -> Result<()> {
        // process all inputs that are currently availalble
        loop {
            let mut current_machine = self.catch_up()?;

            let current_machine_epoch = current_machine.epoch();
            let latest_epoch = self.state_manager.epoch_count()?;

            if current_machine_epoch == latest_epoch {
                // all inputs processed in current epoch
                // epoch may still be open, come back later
                break Ok(());
            } else {
                // epoch is finished
                assert!(current_machine_epoch < latest_epoch);
                self.state_manager.roll_epoch(&mut current_machine)?;
                log::info!("started new epoch {}", current_machine_epoch + 1);
            }
        }
    }

    fn catch_up(&mut self) -> Result<RollupsMachine> {
        loop {
            let mut rollups_machine = self.state_manager.latest_snapshot()?;

            let next = self.state_manager.input(&InputId {
                epoch_number: rollups_machine.epoch(),
                input_index_in_epoch: rollups_machine.input_index_in_epoch(),
            })?;

            match next {
                Some(input) => {
                    log::info!("processing input {}", input.id.input_index_in_epoch);
                    let (state_hashes, reason) = rollups_machine.process_input(&input.data)?;

                    match reason {
                        ManualReason::RxAccepted { .. } => {
                            self.state_manager
                                .advance_accepted(rollups_machine, &state_hashes)?;
                        }
                        _ => {
                            self.state_manager
                                .advance_reverted(rollups_machine, &state_hashes)?;
                        }
                    }
                }
                None => break Ok(rollups_machine),
            }
        }
    }
}
