// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod persistent_state_access;
pub mod rollups_machine;
pub mod state_manager;
pub mod sync;

pub use state_manager::StateAccessError;
pub use state_manager::StateManager;

pub(crate) mod sql;

use cartesi_dave_merkle::Digest;
use cartesi_machine::types::Hash;

pub type Blob = Vec<u8>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitmentLeaf {
    pub hash: Hash,
    pub repetitions: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proof(Vec<[u8; 32]>);

impl Proof {
    pub fn new(siblings: Vec<[u8; 32]>) -> Self {
        Self(siblings)
    }

    pub fn inner(&self) -> Vec<[u8; 32]> {
        self.0.clone()
    }

    fn from_flattened(input: Vec<u8>) -> Self {
        // Ensure the length is a multiple of 32
        assert!(
            input.len() % 32 == 0,
            "Input length must be a multiple of 32"
        );

        let mut result = Vec::new();

        for chunk in input.chunks(32) {
            let mut array = [0u8; 32];
            array.copy_from_slice(chunk);
            result.push(array);
        }

        Proof(result)
    }

    fn flatten(&self) -> Vec<u8> {
        self.0
            .iter()
            .flat_map(|array| array.iter())
            .copied()
            .collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settlement {
    pub computation_hash: Digest,
    pub output_merkle: Hash,
    pub output_proof: Proof,
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
    pub root_tournament: String,
    pub block_created_number: u64,
}
