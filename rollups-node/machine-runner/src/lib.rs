// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;

use error::{MachineRunnerError, Result};
use std::{path::Path, sync::Arc, time::Duration};

use cartesi_compute_core::{
    machine::constants::{LOG2_EMULATOR_SPAN, LOG2_INPUT_SPAN, LOG2_UARCH_SPAN},
    merkle::{Digest, MerkleBuilder},
    utils::arithmetic::max_uint,
};
use cartesi_machine::{break_reason, configuration::RuntimeConfig, htif, machine::Machine};
use rollups_state_manager::{InputId, StateManager};

// gap of each leaf in the commitment tree, should use the same value as CanonicalConstants.sol:log2step(0)
const LOG2_STRIDE: u64 = 30;

pub struct MachineRunner<SM: StateManager> {
    machine: Machine,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    _snapshot_frequency: Duration,

    epoch_number: u64,
    next_input_index_in_epoch: u64,
    state_hash_index_in_epoch: u64,
    // TODO: add computation constants
    // log2_stride_size
    // log2_inputs_in_epoch
    // ...
}

impl<SM: StateManager + std::fmt::Debug> MachineRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        state_manager: Arc<SM>,
        initial_machine: &str,
        sleep_duration: u64,
        snapshot_frequency: u64,
    ) -> Result<Self, SM> {
        let (snapshot, epoch_number, next_input_index_in_epoch) = match state_manager
            .latest_snapshot()
            .map_err(|e| MachineRunnerError::StateManagerError(e))?
        {
            Some(r) => (r.0, r.1, r.2 + 1),
            None => (initial_machine.to_string(), 0, 0),
        };

        let machine = Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?;

        Ok(Self {
            machine,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            _snapshot_frequency: Duration::from_secs(snapshot_frequency),
            epoch_number,
            next_input_index_in_epoch,
            state_hash_index_in_epoch: 0,
        })
    }

    pub fn start(&mut self) -> Result<(), SM> {
        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            std::thread::sleep(self.sleep_duration);
        }
        // TODO: snapshot after some time
    }

    fn process_rollup(&mut self) -> Result<(), SM> {
        // process all inputs that are currently availalble
        loop {
            self.advance_epoch()?;
            let latest_epoch = self
                .state_manager
                .epoch_count()
                .map_err(|e| MachineRunnerError::StateManagerError(e))?;

            if self.epoch_number == latest_epoch {
                break Ok(());
            } else {
                assert!(self.epoch_number < latest_epoch);

                let commitment = self.build_commitment()?;
                self.save_commitment(&commitment)?;

                // end of current epoch
                self.epoch_number += 1;
                self.next_input_index_in_epoch = 0;
                self.state_hash_index_in_epoch = 0;
            }
        }
    }

    fn advance_epoch(&mut self) -> Result<(), SM> {
        loop {
            let next = self
                .state_manager
                .input(&InputId {
                    epoch_number: self.epoch_number,
                    input_index_in_epoch: self.next_input_index_in_epoch,
                })
                .map_err(|e| MachineRunnerError::StateManagerError(e))?;

            match next {
                Some(input) => {
                    self.process_input(&input.data)?;
                    self.next_input_index_in_epoch += 1;
                }
                None => break Ok(()),
            }
        }
    }

    /// calculate computation hash for `self.epoch_number`
    fn build_commitment(&self) -> Result<Vec<u8>, SM> {
        // get all state hashes with repetitions for `self.epoch_number`
        let state_hashes = self
            .state_manager
            .machine_state_hashes(self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;

        let computation_hash = {
            if state_hashes.len() == 0 {
                // no inputs in current epoch, reuse claim from previous epoch
                self.state_manager
                    .computation_hash(self.epoch_number - 1)
                    .map_err(|e| MachineRunnerError::StateManagerError(e))?
                    .unwrap()
            } else {
                let mut builder = MerkleBuilder::default();
                let mut total_repetitions = 0;
                for state_hash in &state_hashes {
                    total_repetitions += state_hash.1;
                    builder.add_with_repetition(
                        Digest::from_digest(&state_hash.0)?,
                        state_hash.1.into(),
                    );
                }

                let stride_count_in_epoch =
                    max_uint(LOG2_INPUT_SPAN + LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);
                builder.add_with_repetition(
                    Digest::from_digest(&state_hashes.last().unwrap().0)?,
                    (stride_count_in_epoch - total_repetitions).into(),
                );

                let tree = builder.build();
                tree.root_hash().slice().to_vec()
            }
        };

        Ok(computation_hash)
    }

    fn save_commitment(&self, computation_hash: &[u8]) -> Result<(), SM> {
        self.state_manager
            .add_computation_hash(computation_hash, self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;

        Ok(())
    }

    fn process_input(&mut self, data: &[u8]) -> Result<(), SM> {
        let big_steps_in_stride = max_uint(LOG2_STRIDE - LOG2_UARCH_SPAN);
        let stride_count_in_input = max_uint(LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);

        self.feed_input(data)?;
        self.run_machine(big_steps_in_stride)?;

        let mut i: u64 = 0;
        while !self.machine.read_iflags_y()? {
            self.add_state_hash(1)?;
            i += 1;
            self.run_machine(big_steps_in_stride)?;
        }
        self.add_state_hash(stride_count_in_input - i)?;

        Ok(())
    }

    fn feed_input(&mut self, input: &[u8]) -> Result<(), SM> {
        self.machine
            .send_cmio_response(htif::fromhost::ADVANCE_STATE, input)?;
        self.machine.reset_iflags_y()?;
        Ok(())
    }

    fn run_machine(&mut self, cycles: u64) -> Result<(), SM> {
        let mcycle = self.machine.read_mcycle()?;

        loop {
            let reason = self.machine.run(mcycle + cycles)?;
            match reason {
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,
                break_reason::YIELDED_MANUALLY | break_reason::REACHED_TARGET_MCYCLE => {
                    break Ok(())
                }
                _ => break Err(MachineRunnerError::MachineRunFail { reason: reason }),
            }
        }
    }

    fn add_state_hash(&mut self, repetitions: u64) -> Result<(), SM> {
        let machine_state_hash = self.machine.get_root_hash()?;
        self.state_manager
            .add_machine_state_hash(
                machine_state_hash.as_bytes(),
                self.epoch_number,
                self.state_hash_index_in_epoch,
                repetitions,
            )
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;
        self.state_hash_index_in_epoch += 1;

        Ok(())
    }
}
