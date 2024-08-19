// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use thiserror::Error;

use crate::InputId;

#[derive(Error, Debug)]
pub enum PersistentStateAccessError {
    #[error(transparent)]
    SQLite {
        #[from]
        source: rusqlite::Error,
    },

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
}

pub type Result<T> = std::result::Result<T, PersistentStateAccessError>;
