// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::{Path, PathBuf};

use cartesi_prt_core::machine::constants::{LOG2_BARCH_SPAN_TO_INPUT, LOG2_UARCH_SPAN_TO_BARCH};

use crate::{CommitmentLeaf, Proof};
use cartesi_machine::{
    config::runtime::{HTIFRuntimeConfig, RuntimeConfig},
    constants::{break_reason, pma::TX_START},
    error::{MachineError, MachineResult},
    machine::Machine,
    types::{Hash, cmio::CmioResponseReason},
};

use thiserror::Error;

#[derive(Error, Debug)]
pub enum StoreError {
    #[error(transparent)]
    MachineError(#[from] MachineError),

    #[error("Failed to cleanup partial store {fs_err}, caused by {machine_err}")]
    CleanupError {
        machine_err: MachineError,
        fs_err: std::io::Error,
    },
}

// gap of each leaf in the commitment tree, should use the same value as ArbitrationConstants.sol:log2step(0)
pub const LOG2_STRIDE: u64 = 44;

const BIG_STEPS_IN_STRIDE: u64 = 1 << (LOG2_STRIDE - LOG2_UARCH_SPAN_TO_BARCH);

const STRIDE_COUNT_IN_INPUT: u64 =
    1 << (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH - LOG2_STRIDE);

pub struct RollupsMachine {
    machine: Machine,
    epoch_number: u64,
    input_index_in_epoch: u64,
}

impl RollupsMachine {
    pub fn new(path: &Path, epoch_number: u64, input_index_in_epoch: u64) -> MachineResult<Self> {
        let runtime_config = RuntimeConfig {
            htif: Some(HTIFRuntimeConfig {
                no_console_putchar: Some(true),
            }),
            ..Default::default()
        };
        let machine = Machine::load(path, &runtime_config)?;

        Ok(Self {
            machine,
            epoch_number,
            input_index_in_epoch,
        })
    }

    pub fn epoch(&self) -> u64 {
        self.epoch_number
    }

    pub fn input_index_in_epoch(&self) -> u64 {
        self.input_index_in_epoch
    }

    pub fn finish_epoch(&mut self) {
        self.epoch_number += 1;
        self.input_index_in_epoch = 0;
    }

    pub fn outputs_proof(&mut self) -> MachineResult<(Hash, Proof)> {
        let proof = self.machine.proof(TX_START, 5)?;
        let siblings = Proof::new(proof.sibling_hashes);
        let output_merkle = self.machine.read_memory(TX_START, 32)?;

        assert_eq!(output_merkle.len(), 32);
        Ok((output_merkle.try_into().unwrap(), siblings))
    }

    pub fn store_if_needed(
        &mut self,
        snapshots_path: &Path,
    ) -> Result<(PathBuf, Hash), StoreError> {
        let state_hash = self.state_hash()?;
        let dest_machine_path = machine_store_path(snapshots_path, &state_hash);

        if !dest_machine_path.exists() {
            let machine_status = self.machine.store(&dest_machine_path);

            if let Err(machine_err) = machine_status {
                // cleanup partial store before returning error.
                let fs_status = std::fs::remove_dir_all(&dest_machine_path);

                // combine errors
                if let Err(fs_err) = fs_status {
                    return Err(StoreError::CleanupError {
                        machine_err,
                        fs_err,
                    });
                } else {
                    return Err(machine_err.into());
                }
            }
        }

        Ok((dest_machine_path, state_hash))
    }

    pub fn state_hash(&mut self) -> MachineResult<Hash> {
        self.machine.root_hash()
    }

    pub fn process_input(&mut self, data: &[u8]) -> MachineResult<Vec<CommitmentLeaf>> {
        let mut state_hashes = Vec::with_capacity(1 << 20);

        self.feed_input(data)?;

        let mut i: u64 = 0;
        while !self.machine.iflags_y()? {
            self.run_machine(BIG_STEPS_IN_STRIDE)?;

            let hash = self.machine.root_hash()?;
            state_hashes.push(CommitmentLeaf {
                hash,
                repetitions: 1,
            });

            i += 1;
        }

        let hash = self.machine.root_hash()?;
        state_hashes.push(CommitmentLeaf {
            hash,
            repetitions: STRIDE_COUNT_IN_INPUT - i,
        });

        self.input_index_in_epoch += 1;
        Ok(state_hashes)
    }

    fn feed_input(&mut self, input: &[u8]) -> MachineResult<()> {
        self.machine
            .send_cmio_response(CmioResponseReason::Advance, input)
    }

    fn run_machine(&mut self, cycles: u64) -> MachineResult<()> {
        let mcycle = self.machine.mcycle()?;

        loop {
            let reason = self.machine.run(mcycle + cycles)?;
            match reason {
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,

                break_reason::YIELDED_MANUALLY | break_reason::REACHED_TARGET_MCYCLE => {
                    break Ok(());
                }

                _ => panic!("machine returned invalid `break_reason` {reason}"),
            }
        }
    }
}

fn machine_store_path(snapshots_path: &Path, state_hash: &cartesi_machine::types::Hash) -> PathBuf {
    snapshots_path.join(format!("0x{}", hex::encode(state_hash)))
}
