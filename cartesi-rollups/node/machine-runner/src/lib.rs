// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod error;
mod rollups_machine;

use alloy::sol_types::private::U256;
use error::Result;
use rollups_machine::RollupsMachine;
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use cartesi_dave_merkle::{Digest, DigestError, MerkleBuilder};
use cartesi_prt_core::machine::constants::{
    LOG2_BARCH_SPAN_TO_INPUT, LOG2_INPUT_SPAN_TO_EPOCH, LOG2_UARCH_SPAN_TO_BARCH,
};
use rollups_state_manager::{CommitmentLeaf, InputId, Settlement, StateManager};

// gap of each leaf in the commitment tree, should use the same value as CanonicalConstants.sol:log2step(0)
const LOG2_STRIDE: u64 = 44;

const STRIDE_COUNT_IN_EPOCH: u64 = 1
    << (LOG2_INPUT_SPAN_TO_EPOCH + LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH
        - LOG2_STRIDE);

const LOG2_STRIDES_PER_INPUT: u64 =
    LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH - LOG2_STRIDE;

const INPUTS_PER_EPOCH: u64 = 1 << LOG2_INPUT_SPAN_TO_EPOCH;

pub struct MachineRunner<SM: StateManager> {
    state_manager: SM,
    state_dir: PathBuf,

    sleep_duration: Duration,
    _snapshot_frequency: Duration,

    state_hash_index_in_epoch: u64,

    rollups_machine: RollupsMachine,
}

impl<SM: StateManager + std::fmt::Debug> MachineRunner<SM> {
    pub fn new(
        mut state_manager: SM,
        initial_machine: &str,
        sleep_duration: u64,
        snapshot_frequency: u64,
        state_dir: PathBuf,
    ) -> Result<Self> {
        let (snapshot, epoch_number, next_input_index_in_epoch) =
            match state_manager.latest_snapshot()? {
                Some(r) => (r.0, r.1, r.2 + 1),
                None => (initial_machine.to_string(), 0, 0),
            };

        // TODO as an optimization, advance snapshot to latest without computation hash, since it's
        // faster.

        let rollups_machine = RollupsMachine::new(
            Path::new(&snapshot),
            epoch_number,
            next_input_index_in_epoch,
        )?;

        Ok(Self {
            state_manager,
            state_dir,

            sleep_duration: Duration::from_secs(sleep_duration),
            _snapshot_frequency: Duration::from_secs(snapshot_frequency),

            // TODO: currently this works because we only save
            // snapshot in the begining of the epoch.
            state_hash_index_in_epoch: 0,

            rollups_machine,
        })
    }

    pub fn start(&mut self) -> Result<()> {
        self.take_snapshot()?; // checkpoint

        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            std::thread::sleep(self.sleep_duration);

            // TODO: snapshot after some time
        }
    }

    fn process_rollup(&mut self) -> Result<()> {
        // process all inputs that are currently availalble
        loop {
            self.advance_epoch()?;

            let latest_epoch = self.state_manager.epoch_count()?;

            if self.rollups_machine.epoch() == latest_epoch {
                // all inputs processed in current epoch
                // epoch may still be open, come back later
                break Ok(());
            } else {
                // epoch has advanced, fill in the rest of machine state hashes of self.epoch_number, and checkpoint
                assert!(self.rollups_machine.epoch() < latest_epoch);

                self.add_remaining_strides()?;
                self.save_settlement_info()?; // checkpoint
                self.rollups_machine.finish_epoch();
                self.state_hash_index_in_epoch = 0;
                self.take_snapshot()?; // checkpoint
            }
        }
    }

    fn advance_epoch(&mut self) -> Result<()> {
        loop {
            let next = self.state_manager.input(&InputId {
                epoch_number: self.rollups_machine.epoch(),
                input_index_in_epoch: self.rollups_machine.input_index_in_epoch(),
            })?;

            match next {
                Some(input) => {
                    let state_hashes = self.rollups_machine.process_input(&input.data)?;
                    self.add_state_hashes(&state_hashes)?;
                }
                None => break Ok(()),
            }
        }
    }

    fn add_remaining_strides(&mut self) -> Result<()> {
        assert!(self.rollups_machine.input_index_in_epoch() < INPUTS_PER_EPOCH);

        let remaining_inputs = INPUTS_PER_EPOCH - self.rollups_machine.input_index_in_epoch();
        let remaining_strides = remaining_inputs << LOG2_STRIDES_PER_INPUT;

        if remaining_strides > 0 {
            let hash = self.rollups_machine.state_hash()?;
            self.add_state_hashes(&[CommitmentLeaf {
                hash,
                repetitions: remaining_strides,
            }])?;
        }

        Ok(())
    }

    fn add_state_hashes(&mut self, state_hashes: &[CommitmentLeaf]) -> Result<()> {
        self.state_manager.add_machine_state_hashes(
            self.rollups_machine.epoch(),
            self.state_hash_index_in_epoch,
            state_hashes,
        )?;

        self.state_hash_index_in_epoch += state_hashes.len() as u64;

        Ok(())
    }

    fn save_settlement_info(&mut self) -> Result<()> {
        let epoch_number = self.rollups_machine.epoch();

        let state_hashes = self.state_manager.machine_state_hashes(epoch_number)?;

        let computation_hash = build_commitment_from_hashes(&state_hashes)?;

        let (output_merkle, output_proof) = self.rollups_machine.outputs_proof()?;

        self.state_manager.add_settlement_info(
            &Settlement {
                computation_hash,
                output_merkle,
                output_proof,
            },
            epoch_number,
        )?;

        Ok(())
    }

    fn take_snapshot(&mut self) -> Result<()> {
        let epoch_number = self.rollups_machine.epoch();
        let input_index_in_epoch = self.rollups_machine.input_index_in_epoch();

        let epoch_path = self
            .state_dir
            .join("snapshots")
            .join(epoch_number.to_string());

        if !epoch_path.exists() {
            fs::create_dir_all(&epoch_path)?;
        }

        let snapshot_path = epoch_path.join(format!(
            "{}",
            input_index_in_epoch << LOG2_BARCH_SPAN_TO_INPUT
        ));

        if !snapshot_path.exists() {
            self.rollups_machine.store(&snapshot_path)?;

            self.state_manager.add_snapshot(
                snapshot_path
                    .to_str()
                    .expect("fail to convert snapshot path"),
                epoch_number,
                input_index_in_epoch,
            )?;
        }

        Ok(())
    }
}

fn build_commitment_from_hashes(
    state_hashes: &Vec<CommitmentLeaf>,
) -> std::result::Result<Digest, DigestError> {
    let computation_hash = {
        let mut builder = MerkleBuilder::default();

        for state_hash in state_hashes {
            builder.append_repeated(
                Digest::from_digest(&state_hash.hash)?,
                state_hash.repetitions,
            );
        }

        assert_eq!(builder.count().unwrap(), U256::from(STRIDE_COUNT_IN_EPOCH));
        let tree = builder.build();
        tree.root_hash()
    };

    Ok(computation_hash)
}

/*
#[cfg(test)]
mod tests {
    use crate::{
        build_commitment_from_hashes, LOG2_BARCH_SPAN_TO_INPUT, LOG2_INPUT_SPAN_TO_EPOCH,
        LOG2_STRIDE, LOG2_UARCH_SPAN_TO_BARCH,
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

    /*
    #[test]
    fn test_commitment_builder() -> std::result::Result<(), Box<dyn std::error::Error>> {
        let repetitions = vec![1, 2, 1 << 24, (1 << 48) - 1, 1 << 48];
        let stride_count_in_epoch = 1
            << (LOG2_INPUT_SPAN_TO_EPOCH + LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH
                - LOG2_STRIDE);
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
    */
}
*/
