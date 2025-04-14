// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod persistent_state_access;

pub(crate) mod sql;

use std::error::Error;
pub type Blob = Vec<u8>;

#[derive(Debug, PartialEq)]
pub struct Proof(Vec<[u8; 32]>);
impl From<Vec<u8>> for Proof {
    fn from(input: Vec<u8>) -> Self {
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
}

impl Proof {
    pub fn new(siblings: Vec<[u8; 32]>) -> Self {
        Self(siblings)
    }

    pub fn inner(&self) -> Vec<[u8; 32]> {
        self.0.clone()
    }

    fn flatten(&self) -> Vec<u8> {
        self.0
            .iter()
            .flat_map(|array| array.iter())
            .copied()
            .collect()
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
    pub root_tournament: String,
    pub block_created_number: u64,
}

pub trait StateManager {
    type Error: Error;

    //
    // Consensus Data
    //

    fn epoch(&self, epoch_number: u64) -> Result<Option<Epoch>, Self::Error>;
    fn epoch_count(&self) -> Result<u64, Self::Error>;
    fn last_sealed_epoch(&self) -> Result<Option<Epoch>, Self::Error>;
    fn input(&self, id: &InputId) -> Result<Option<Input>, Self::Error>;
    fn inputs(&self, epoch_number: u64) -> Result<Vec<Vec<u8>>, Self::Error>;
    fn input_count(&self, epoch_number: u64) -> Result<u64, Self::Error>;
    fn last_input(&self) -> Result<Option<InputId>, Self::Error>;
    fn insert_consensus_data<'a>(
        &self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<(), Self::Error>;
    fn latest_processed_block(&self) -> Result<u64, Self::Error>;

    //
    // Rollup Data
    //

    fn add_machine_state_hash(
        &self,
        machine_state_hash: &[u8],
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
        repetitions: u64,
    ) -> Result<(), Self::Error>;
    fn machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<(Vec<u8>, u64), Self::Error>;
    fn machine_state_hashes(&self, epoch_number: u64) -> Result<Vec<(Vec<u8>, u64)>, Self::Error>;
    fn settlement_info(
        &self,
        epoch_number: u64,
    ) -> Result<Option<(Vec<u8>, Vec<u8>, Proof)>, Self::Error>;
    fn add_settlement_info(
        &self,
        computation_hash: &[u8],
        output_merkle: &[u8],
        output_proof: &Proof,
        epoch_number: u64,
    ) -> Result<(), Self::Error>;
    fn add_snapshot(
        &self,
        path: &str,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<(), Self::Error>;
    fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>, Self::Error>;
    fn snapshot(
        &self,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<Option<String>, Self::Error>;
}
