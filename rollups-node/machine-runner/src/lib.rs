use anyhow::Result;
use std::{path::Path, sync::Arc, time::Duration};

use cartesi_compute_core::merkle::{Digest, MerkleBuilder};
use cartesi_machine::{break_reason, configuration::RuntimeConfig, htif, machine::Machine};
use rollups_state_manager::{InputId, StateManager};

// TODO: setup constants for commitment builder
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

impl<SM: StateManager> MachineRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        state_manager: Arc<SM>,
        initial_machine: &str,
        sleep_duration: Duration,
        _snapshot_frequency: Duration,
    ) -> Result<Self> {
        let (snapshot, epoch_number, next_input_index_in_epoch) =
            match state_manager.latest_snapshot()? {
                Some(r) => (r.0, r.1, r.2 + 1),
                None => (initial_machine.to_string(), 0, 0),
            };

        let machine = Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?;

        Ok(Self {
            machine,
            sleep_duration,
            state_manager,
            _snapshot_frequency,
            epoch_number,
            next_input_index_in_epoch,
            state_hash_index_in_epoch: 0,
        })
    }

    pub fn start(&mut self) -> Result<()> {
        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            std::thread::sleep(self.sleep_duration);
        }
        // TODO: snapshot after some time
    }

    fn process_rollup(&mut self) -> Result<()> {
        // process all inputs that are currently availalble
        loop {
            self.advance_epoch()?;
            let latest_epoch = self.state_manager.epoch_count()?;

            if self.epoch_number == latest_epoch {
                break Ok(());
            } else {
                assert!(self.epoch_number < latest_epoch);

                self.build_and_save_commitment()?;
                // end of current epoch
                self.epoch_number += 1;
                self.next_input_index_in_epoch = 0;
                self.state_hash_index_in_epoch = 0;
            }
        }
    }

    fn advance_epoch(&mut self) -> Result<()> {
        loop {
            let next = self.state_manager.input(&InputId {
                epoch_number: self.epoch_number,
                input_index_in_epoch: self.next_input_index_in_epoch,
            })?;

            match next {
                Some(input) => {
                    self.process_input(&input.data)?;
                    self.next_input_index_in_epoch += 1;
                }
                None => break Ok(()),
            }
        }
    }

    fn build_and_save_commitment(&self) -> Result<()> {
        // get all state hashes with repetitions for `self.epoch_number`
        let state_hashes = self.state_manager.machine_state_hashes(self.epoch_number)?;

        let computation_hash = {
            if state_hashes.len() == 0 {
                // no inputs in current epoch, reuse claim from previous epoch
                self.state_manager
                    .computation_hash(self.epoch_number - 1)?
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

                // TODO: validate total repetitions match epoch length
                let number_of_leaves_in_an_epoch = 1 << 10;
                builder.add_with_repetition(
                    Digest::from_digest(&state_hashes.last().unwrap().0)?,
                    (number_of_leaves_in_an_epoch - total_repetitions).into(),
                );

                let tree = builder.build();
                tree.root_hash().slice().to_vec()
            }
        };

        self.state_manager
            .add_computation_hash(&computation_hash, self.epoch_number)?;

        Ok(())
    }

    fn process_input(&mut self, data: &[u8]) -> Result<()> {
        // TODO: setup constants
        let stride = 1 << 30;
        let b = 1 << 48;
        //

        self.feed_input(data)?;
        self.run_machine(stride)?;

        let mut i: u64 = 0;
        while !self.machine.read_iflags_y()? {
            self.add_state_hash(1)?;
            self.run_machine(stride)?;
            i += 1;
        }
        self.add_state_hash(b - i)?;

        Ok(())
    }

    fn feed_input(&mut self, input: &[u8]) -> Result<()> {
        self.machine
            .send_cmio_response(htif::fromhost::ADVANCE_STATE, input)?;
        self.machine.reset_iflags_y()?;
        Ok(())
    }

    fn run_machine(&mut self, cycles: u64) -> Result<()> {
        let mcycle = self.machine.read_mcycle()?;

        loop {
            let reason = self.machine.run(mcycle + cycles)?;
            match reason {
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,
                break_reason::YIELDED_MANUALLY | break_reason::REACHED_TARGET_MCYCLE => {
                    break Ok(())
                }
                _ => break Err(anyhow::anyhow!(reason.to_string())),
            }
        }
    }

    fn add_state_hash(&mut self, repetitions: u64) -> Result<()> {
        let machine_state_hash = self.machine.get_root_hash()?;
        self.state_manager.add_machine_state_hash(
            machine_state_hash.as_bytes(),
            self.epoch_number,
            self.state_hash_index_in_epoch,
            repetitions,
        )?;
        self.state_hash_index_in_epoch += 1;

        Ok(())
    }
}
