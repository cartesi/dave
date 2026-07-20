// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::storage::InputId;
use cartesi_machine::error::MachineError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum StorageError {
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

    #[error("Couldn't find data: `{description}`")]
    DataNotFound { description: String },

    #[error("Machine snapshot error")]
    MachineError {
        #[from]
        source: MachineError,
    },

    #[error("Inner error: `{0}`")]
    InnerError(#[from] anyhow::Error),
}

pub type Result<T> = std::result::Result<T, StorageError>;
