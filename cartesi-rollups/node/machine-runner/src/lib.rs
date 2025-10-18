// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod error;

use error::Result;
use std::{ops::ControlFlow, time::Duration};

use cartesi_machine::types::cmio::ManualReason;
use rollups_state_manager::{InputId, StateManager, sync::Watch};
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
            self.catch_up()?;

            let current_machine_epoch = self.state_manager.next_input_id()?.epoch_number;
            let latest_blockchain_epoch = self.state_manager.epoch_count()?;

            if current_machine_epoch == latest_blockchain_epoch {
                // all current inputs processed in current epoch, which is still open.
                // sleep and come back later.
                break Ok(());
            } else {
                // epoch is finished, all inputs processed
                assert!(current_machine_epoch < latest_blockchain_epoch);
                self.state_manager.roll_epoch()?;
                log::info!("started new epoch {}", current_machine_epoch + 1);
            }
        }
    }

    fn catch_up(&mut self) -> Result<()> {
        let mut rollups_machine = self.state_manager.latest_snapshot()?;

        loop {
            let input_id = InputId {
                epoch_number: rollups_machine.epoch(),
                input_index_in_epoch: rollups_machine.input_index_in_epoch(),
            };

            let input = self.state_manager.input(&input_id)?;

            match input {
                Some(input) => {
                    log::info!("processing input {}", input.id.input_index_in_epoch);
                    let (state_hashes, reason) = rollups_machine.process_input(&input.data)?;

                    match reason {
                        ManualReason::RxAccepted { .. } => {
                            self.state_manager
                                .advance_accepted(&mut rollups_machine, &state_hashes)?;
                        }
                        _ => {
                            rollups_machine = self
                                .state_manager
                                .advance_reverted(&input_id, &state_hashes)?;
                        }
                    }
                }
                None => break Ok(()),
            }
        }
    }
}
