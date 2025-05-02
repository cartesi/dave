// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{CommitmentLeaf, Epoch, Input, InputId, Settlement};
use thiserror::Error;

pub trait StateManager {
    //
    // Consensus Data
    //

    fn epoch(&self, epoch_number: u64) -> Result<Option<Epoch>>;
    fn epoch_count(&self) -> Result<u64>;
    fn last_sealed_epoch(&self) -> Result<Option<Epoch>>;
    fn input(&self, id: &InputId) -> Result<Option<Input>>;
    fn inputs(&self, epoch_number: u64) -> Result<Vec<Vec<u8>>>;
    fn input_count(&self, epoch_number: u64) -> Result<u64>;
    fn last_input(&self) -> Result<Option<InputId>>;
    fn insert_consensus_data<'a>(
        &self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()>;
    fn latest_processed_block(&self) -> Result<u64>;

    //
    // Rollup Data
    //

    fn add_machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
        leaf: &CommitmentLeaf,
    ) -> Result<()>;

    fn machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<Option<CommitmentLeaf>>;

    fn machine_state_hashes(&self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>>;

    fn settlement_info(&self, epoch_number: u64) -> Result<Option<Settlement>>;

    fn add_settlement_info(&self, settlement: &Settlement, epoch_number: u64) -> Result<()>;

    fn add_snapshot(&self, path: &str, epoch_number: u64, input_index_in_epoch: u64) -> Result<()>;

    fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>>;

    fn snapshot(&self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Option<String>>;
}

#[derive(Error, Debug)]
pub enum StateAccessError {
    #[error("Supplied block `{provided}` is smaller than last processed `{last}`")]
    InconsistentLastProcessed { last: u64, provided: u64 },

    #[error("Supplied Epoch is inconsistent: expected `{expected}`, got `{provided}`")]
    InconsistentEpoch { expected: u64, provided: u64 },

    #[error(
        "Supplied Input is inconsistent: previous is `{:?}`, got `{:?}`",
        previous,
        provided
    )]
    InconsistentInput {
        previous: Option<InputId>,
        provided: InputId,
    },

    #[error("Duplicate entry: `{description}`")]
    DuplicateEntry { description: String },

    #[error("Failed to insert data: `{description}`")]
    InsertionFailed { description: String },

    #[error("Couldn't find data: `{description}`")]
    DataNotFound { description: String },

    #[error("Inner error: `{0}`")]
    InnerError(#[from] anyhow::Error),
}

pub type Result<T> = std::result::Result<T, StateAccessError>;
