// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{CommitmentLeaf, Epoch, Input, InputId, Settlement};
use thiserror::Error;

pub trait StateManager {
    //
    // Consensus Data
    //

    fn set_genesis(&mut self, block_number: u64) -> Result<()>;
    fn epoch(&mut self, epoch_number: u64) -> Result<Option<Epoch>>;
    fn epoch_count(&mut self) -> Result<u64>;
    fn last_sealed_epoch(&mut self) -> Result<Option<Epoch>>;
    fn input(&mut self, id: &InputId) -> Result<Option<Input>>;
    fn inputs(&mut self, epoch_number: u64) -> Result<Vec<Vec<u8>>>;
    fn input_count(&mut self, epoch_number: u64) -> Result<u64>;
    fn last_input(&mut self) -> Result<Option<InputId>>;
    fn insert_consensus_data<'a>(
        &mut self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()>;
    fn latest_processed_block(&mut self) -> Result<u64>;

    //
    // Rollup Data
    //

    fn add_machine_state_hashes(
        &mut self,
        epoch_number: u64,
        start_state_hash_index: u64,
        leafs: &[CommitmentLeaf],
    ) -> Result<()>;

    fn machine_state_hash(
        &mut self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<Option<CommitmentLeaf>>;

    fn machine_state_hashes(&mut self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>>;

    fn settlement_info(&mut self, epoch_number: u64) -> Result<Option<Settlement>>;

    fn add_settlement_info(&mut self, settlement: &Settlement, epoch_number: u64) -> Result<()>;

    fn add_snapshot(
        &mut self,
        path: &str,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<()>;

    fn latest_snapshot(&mut self) -> Result<Option<(String, u64, u64)>>;

    fn snapshot(&mut self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Option<String>>;
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
