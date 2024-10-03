// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use thiserror::Error;

#[derive(Error, Debug)]
pub enum DisputeStateAccessError {
    #[error(transparent)]
    IO {
        #[from]
        source: std::io::Error,
    },

    #[error(transparent)]
    Serde {
        #[from]
        source: serde_json::Error,
    },

    #[error(transparent)]
    SQLite {
        #[from]
        source: rusqlite::Error,
    },

    #[error("Duplicate entry: `{description}`")]
    DuplicateEntry { description: String },

    #[error("Failed to insert data: `{description}`")]
    InsertionFailed { description: String },

    #[error("Couldn't find data: `{description}`")]
    DataNotFound { description: String },
}

pub type Result<T> = std::result::Result<T, DisputeStateAccessError>;
