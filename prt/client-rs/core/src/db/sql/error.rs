// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use thiserror::Error;

#[derive(Error, Debug)]
pub enum ComputeStateAccessError {
    #[error(transparent)]
    Digest {
        #[from]
        source: cartesi_dave_merkle::DigestError,
    },

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

    #[error("Failed to insert data: `{description}`")]
    InsertionFailed { description: String },
}

pub type Result<T> = std::result::Result<T, ComputeStateAccessError>;
