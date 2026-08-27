// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The node's one durable state surface: a single SQLite database
//! plus the content-addressed snapshot store, behind domain
//! operations that preserve the state invariants internally.
//!
//! Layout: `open` owns
//! the connection lifecycle and the transaction closure helpers;
//! `ingest` is the blockchain reader's writer role, `advance` the
//! machine runner's, `dispute` the hero's; `queries` is the
//! role-free read surface; `sql` holds the DDL and its discipline
//! tests. Every table belongs to one of four mutation classes -
//! append-only log, write-once cell, monotonic watermark, prunable
//! derived store - enforced by triggers in the schema itself.

pub mod error;
pub mod rollups_machine;

pub use error::StorageError;

mod advance;
mod convert;
mod dispute;
mod ingest;
pub(crate) mod open;
mod queries;
mod snapshots;
pub(crate) mod sql;

pub use advance::AdvanceBatch;
pub(crate) use advance::AdvancePlan;
pub use open::{DEFAULT_SNAPSHOT_GAP_INPUTS, Storage};

use self::error::Result;
use crate::merkle::Digest;
use alloy::primitives::Address;
use cartesi_machine::types::Hash;
use std::fmt;

pub type Blob = Vec<u8>;

pub const MACHINE_MEMORY_PROOF_SIBLING_COUNT: usize = 59;
const MACHINE_MEMORY_PROOF_BYTES: usize = MACHINE_MEMORY_PROOF_SIBLING_COUNT * 32;

#[derive(Clone, PartialEq, Eq)]
pub struct Proof([Hash; MACHINE_MEMORY_PROOF_SIBLING_COUNT]);

impl Proof {
    pub fn new(siblings: Vec<Hash>) -> Result<Self> {
        let actual = siblings.len();
        let siblings = siblings.try_into().map_err(|_| {
            anyhow::anyhow!(
                "machine memory proof has {actual} siblings, expected {MACHINE_MEMORY_PROOF_SIBLING_COUNT}"
            )
        })?;
        Ok(Self(siblings))
    }

    pub fn inner(&self) -> &[Hash] {
        &self.0
    }

    pub(crate) fn from_flattened(input: Vec<u8>) -> Result<Self> {
        if input.len() != MACHINE_MEMORY_PROOF_BYTES {
            return Err(anyhow::anyhow!(
                "stored machine memory proof has {} bytes, expected {MACHINE_MEMORY_PROOF_BYTES}",
                input.len(),
            )
            .into());
        }

        let mut result = Vec::with_capacity(MACHINE_MEMORY_PROOF_SIBLING_COUNT);
        for chunk in input.chunks(32) {
            let mut array = [0u8; 32];
            array.copy_from_slice(chunk);
            result.push(array);
        }

        Self::new(result)
    }

    pub(crate) fn flatten(&self) -> Vec<u8> {
        self.0
            .iter()
            .flat_map(|array| array.iter())
            .copied()
            .collect()
    }
}

impl fmt::Debug for Proof {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Proof")
            .field("sibling_count", &self.0.len())
            .field("first", &self.0.first())
            .field("last", &self.0.last())
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeafProof {
    pub data_block: Hash,
    pub siblings: Proof,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MachineValidityProof {
    pub iflags_y_proof: LeafProof,
    pub htif_tohost_proof: LeafProof,
    pub tx_buffer_proof: LeafProof,
}

impl MachineValidityProof {
    pub fn outputs_merkle_root(&self) -> Hash {
        self.tx_buffer_proof.data_block
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settlement {
    pub computation_hash: Digest,
    /// The post-epoch machine state hash: the new epoch's initial
    /// boundary, claimed by sentries and staged on-chain.
    pub final_state: Hash,
    pub machine_validity_proof: MachineValidityProof,
}

impl Settlement {
    pub fn outputs_merkle_root(&self) -> Hash {
        self.machine_validity_proof.outputs_merkle_root()
    }
}

#[derive(Clone, Debug, Default)]
pub struct InputId {
    pub epoch_number: u64,
    pub input_index_in_epoch: u64,
}

impl InputId {
    pub fn increment_index(self) -> Self {
        Self {
            epoch_number: self.epoch_number,
            input_index_in_epoch: self.input_index_in_epoch + 1,
        }
    }

    pub fn increment_epoch(self) -> Self {
        Self {
            epoch_number: self.epoch_number + 1,
            input_index_in_epoch: 0,
        }
    }

    pub fn validate_next(&self, next: &Self) -> bool {
        match self {
            InputId {
                epoch_number,
                input_index_in_epoch,
            } if next.epoch_number == *epoch_number
                && next.input_index_in_epoch == input_index_in_epoch + 1 =>
            {
                true
            }

            InputId { epoch_number, .. }
                if next.epoch_number > *epoch_number && next.input_index_in_epoch == 0 =>
            {
                true
            }

            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Input {
    pub id: InputId,
    pub data: Blob,
}

#[derive(Clone, Debug)]
pub struct Epoch {
    pub epoch_number: u64,
    pub input_index_boundary: u64,
    pub root_tournament: Address,
    pub block_created_number: u64,
}

#[cfg(test)]
mod tests {
    use super::sql::test_helper::setup_storage;
    use super::*;
    use crate::merkle::MerkleBuilder;

    /// The whole advance lifecycle through the public surface:
    /// consensus ingest, a committed advance batch with an accepted
    /// and a reverted input, and the epoch roll's settlement.
    #[test]
    fn test_state_access() -> Result<()> {
        let input_0_bytes = b"hello";
        let input_1_bytes = b"world";

        let (_handle, mut access) = setup_storage();

        access.insert_consensus_data(
            20,
            [
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 0,
                    },
                    data: input_0_bytes.to_vec(),
                },
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 1,
                    },
                    data: input_1_bytes.to_vec(),
                },
            ]
            .into_iter(),
            [&Epoch {
                epoch_number: 0,
                input_index_boundary: 12,
                root_tournament: Address::ZERO,
                block_created_number: 0,
            }]
            .into_iter(),
        )?;

        assert_eq!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                })?
                .map(|x| x.data),
            Some(input_0_bytes.to_vec()),
            "input 0 bytes should match"
        );
        assert!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 2
                })?
                .is_none(),
            "input 2 shouldn't exist"
        );

        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 1,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "duplicate input index should fail"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 3,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "input index should be sequential"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 2,
                        },
                        data: input_1_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_ok(),
            "add sequential input should succeed"
        );

        assert_eq!(
            access.latest_processed_block()?,
            21,
            "latest block should match"
        );

        // One batch: an accepted input, then two reverted ones. The
        // rejected inputs share the accepted input's final boundary.
        let (mut machine, mut batch) = access.begin_advances()?;
        assert_eq!(machine.epoch(), 0);

        // Records must tile their window and their final run must
        // carry the machine's boundary state (the record asserts it);
        // the machine never runs in this storage-level test, so every
        // boundary is the template hash.
        let machine_hash = Digest::new(machine.state_hash()?);
        let window_0 = vec![
            crate::engine::Run {
                hash: Digest::new([1; 32]),
                repetitions: alloy::primitives::U256::from(7),
            },
            crate::engine::Run {
                hash: machine_hash,
                repetitions: alloy::primitives::U256::from(
                    rollups_machine::STRIDE_COUNT_IN_INPUT - 7,
                ),
            },
        ];
        let window_1 = vec![crate::engine::Run {
            hash: machine_hash,
            repetitions: alloy::primitives::U256::from(rollups_machine::STRIDE_COUNT_IN_INPUT),
        }];

        machine.increment_input();
        access.record_accepted(&mut batch, &mut machine, &window_0)?;

        machine.increment_input();
        access.record_reverted(&mut batch, &mut machine, &window_1)?;

        machine.increment_input();
        access.record_reverted(&mut batch, &mut machine, &window_1)?;
        assert_eq!(
            machine.next_input_index_in_epoch(),
            3,
            "the reverted machine resumes after the rejected input"
        );

        assert_eq!(batch.len(), 3);
        drop(machine);
        access.commit_advances(batch)?;

        assert_eq!(
            access.window_root_count(
                0,
                rollups_machine::LOG2_STRIDE,
                rollups_machine::LOG2_STRIDE_COUNT_IN_INPUT,
                3
            )?,
            3,
            "all windows landed their root rows"
        );

        assert_eq!(
            access.next_input_id()?.input_index_in_epoch,
            3,
            "the committed batch is the resume point"
        );

        assert!(
            access.settlement_info(1)?.is_none(),
            "computation_hash shouldn't exist"
        );

        let (final_state, machine_validity_proof) = {
            let mut machine = access.latest_snapshot()?;
            machine.machine_validity_proof()?
        };
        access.roll_epoch()?;
        assert_eq!(access.latest_snapshot()?.epoch(), 1);

        // The independent expectation is the naive flat fold of the
        // whole epoch (every run, tail-padded to 2^48 leaves) - the
        // roll's window-root composition must equal it exactly.
        let expected_root = {
            let mut builder = MerkleBuilder::default();
            builder.append_repeated(Digest::new([1; 32]), 7u64);
            builder.append_repeated(machine_hash, rollups_machine::STRIDE_COUNT_IN_EPOCH - 7);
            builder.build().root_hash()
        };
        assert_eq!(
            access.settlement_info(0)?.unwrap(),
            Settlement {
                computation_hash: expected_root,
                final_state,
                machine_validity_proof
            },
            "settlement info of epoch 0 should match"
        );

        Ok(())
    }
}
