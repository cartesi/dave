// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;

use alloy::sol_types::private::U256;
use error::{MachineRunnerError, Result};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use cartesi_dave_merkle::{Digest, DigestError, MerkleBuilder};
use cartesi_machine::{
    break_reason, configuration::RuntimeConfig, hash::Hash, htif, machine::Machine,
};
use cartesi_prt_core::machine::constants::{LOG2_EMULATOR_SPAN, LOG2_INPUT_SPAN, LOG2_UARCH_SPAN};
use rollups_state_manager::{InputId, StateManager};

// gap of each leaf in the commitment tree, should use the same value as CanonicalConstants.sol:log2step(0)
const LOG2_STRIDE: u64 = 44;

pub struct MachineRunner<SM: StateManager> {
    machine: Machine,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    _snapshot_frequency: Duration,
    state_dir: PathBuf,

    epoch_number: u64,
    next_input_index_in_epoch: u64,
    state_hash_index_in_epoch: u64,
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
        state_dir: PathBuf,
    ) -> Result<Self, SM> {
        let (snapshot, epoch_number, next_input_index_in_epoch) = match state_manager
            .latest_snapshot()
            .map_err(|e| MachineRunnerError::StateManagerError(e))?
        {
            Some(r) => (r.0, r.1, r.2 + 1),
            None => (initial_machine.to_string(), 0, 0),
        };

        let machine = Machine::load(Path::new(&snapshot), RuntimeConfig::default())?;

        Ok(Self {
            machine,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            _snapshot_frequency: Duration::from_secs(snapshot_frequency),
            state_dir,

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
                // all inputs processed in current epoch
                // epoch may still be open, come back later
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
        if self.next_input_index_in_epoch == 0 {
            self.take_snapshot()?;
        }
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
    fn build_commitment(&mut self) -> Result<Vec<u8>, SM> {
        // get all state hashes with repetitions for `self.epoch_number`
        let mut state_hashes = self
            .state_manager
            .machine_state_hashes(self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;
        let stride_count_in_epoch =
            1 << (LOG2_INPUT_SPAN + LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);
        if state_hashes.is_empty() {
            // no inputs in current epoch, add machine state hash repeatedly
            let machine_state_hash = self.add_state_hash(stride_count_in_epoch)?;
            state_hashes.push((
                machine_state_hash.as_bytes().to_vec(),
                stride_count_in_epoch,
            ));
        }

        let (computation_hash, total_repetitions) =
            build_commitment_from_hashes(state_hashes, stride_count_in_epoch)?;
        if stride_count_in_epoch > total_repetitions {
            self.add_state_hash(stride_count_in_epoch - total_repetitions)?;
        }

        Ok(computation_hash)
    }

    fn save_commitment(&self, computation_hash: &[u8]) -> Result<(), SM> {
        self.state_manager
            .add_computation_hash(computation_hash, self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;

        Ok(())
    }

    fn process_input(&mut self, data: &[u8]) -> Result<(), SM> {
        // TODO: review caclulations
        let big_steps_in_stride = 1 << (LOG2_STRIDE - LOG2_UARCH_SPAN);
        let stride_count_in_input = 1 << (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);

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
                _ => break Err(MachineRunnerError::MachineRunFail { reason }),
            }
        }
    }

    fn add_state_hash(&mut self, repetitions: u64) -> Result<Hash, SM> {
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

        Ok(machine_state_hash)
    }

    fn take_snapshot(&self) -> Result<(), SM> {
        let epoch_path = self
            .state_dir
            .join("snapshots")
            .join(self.epoch_number.to_string());

        if !epoch_path.exists() {
            fs::create_dir_all(&epoch_path)?;
        }

        let snapshot_path = epoch_path.join(format!(
            "{}",
            self.next_input_index_in_epoch << LOG2_EMULATOR_SPAN
        ));

        if !snapshot_path.exists() {
            self.state_manager
                .add_snapshot(
                    snapshot_path
                        .to_str()
                        .expect("fail to convert snapshot path"),
                    self.epoch_number,
                    self.next_input_index_in_epoch,
                )
                .map_err(|e| MachineRunnerError::StateManagerError(e))?;
            self.machine.store(&snapshot_path)?;
        }

        Ok(())
    }
}

fn build_commitment_from_hashes(
    state_hashes: Vec<(Vec<u8>, u64)>,
    stride_count_in_epoch: u64,
) -> std::result::Result<(Vec<u8>, u64), DigestError> {
    let mut total_repetitions = 0;
    let computation_hash = {
        let mut builder = MerkleBuilder::default();
        for state_hash in &state_hashes {
            total_repetitions += state_hash.1;
            builder.append_repeated(
                Digest::from_digest(&state_hash.0)?,
                U256::from(state_hash.1),
            );
        }
        if stride_count_in_epoch > total_repetitions {
            builder.append_repeated(
                Digest::from_digest(&state_hashes.last().unwrap().0)?,
                U256::from(stride_count_in_epoch - total_repetitions),
            );
        }

        let tree = builder.build();
        tree.root_hash().slice().to_vec()
    };

    Ok((computation_hash, total_repetitions))
}

#[cfg(test)]
mod tests {
    use crate::{
        build_commitment_from_hashes, LOG2_EMULATOR_SPAN, LOG2_INPUT_SPAN, LOG2_STRIDE,
        LOG2_UARCH_SPAN,
    };

    fn hex_to_bytes(s: &str) -> Option<Vec<u8>> {
        if s.len() % 2 == 0 {
            (0..s.len())
                .step_by(2)
                .map(|i| {
                    s.get(i..i + 2)
                        .and_then(|sub| u8::from_str_radix(sub, 16).ok())
                })
                .collect()
        } else {
            None
        }
    }

    #[test]
    fn test_commitment_builder() -> std::result::Result<(), Box<dyn std::error::Error>> {
        let repetitions = vec![1, 2, 1 << 24, (1 << 48) - 1, 1 << 48];
        let stride_count_in_epoch =
            1 << (LOG2_INPUT_SPAN + LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);
        let mut machine_state_hash =
            hex_to_bytes("AAA646181BF25FD29FBB7D468E786F8B6F7215D53CE4F7C69A108FB8099555B7")
                .unwrap();
        let mut computation_hash =
            hex_to_bytes("FB6E8E3659EC96D086402465894894B0B4D267023A26D25F0147C1F00D350FAE")
                .unwrap();

        for rep in &repetitions {
            assert_eq!(
                build_commitment_from_hashes(
                    vec![(machine_state_hash.clone(), *rep)],
                    stride_count_in_epoch
                )?,
                (computation_hash.clone(), *rep),
                "computation hash and repetition should match"
            );
        }

        machine_state_hash =
            hex_to_bytes("5F0F4E3F7F266592691376743C5D558C781654CDFDC5AC8B002ECF5F899B789C")
                .unwrap();
        computation_hash =
            hex_to_bytes("8AC7CD8E381CCFF6DB21F66B30F9AC69794394EB352E533C5ED0A8C175AAAF47")
                .unwrap();

        for rep in &repetitions {
            assert_eq!(
                build_commitment_from_hashes(
                    vec![(machine_state_hash.clone(), *rep)],
                    stride_count_in_epoch
                )?,
                (computation_hash.clone(), *rep),
                "computation hash and repetition should match"
            );
        }

        Ok(())
    }
}
