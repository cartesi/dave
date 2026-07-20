// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use alloy::contract::Error as AlloyContractError;
use anyhow::Error as AnyhowError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ReactError {
    #[error(transparent)]
    Storage {
        #[from]
        source: crate::storage::StorageError,
    },

    #[error(transparent)]
    AlloyContract {
        #[from]
        source: AlloyContractError,
    },

    #[error(transparent)]
    Anyhow {
        #[from]
        source: AnyhowError,
    },
}

pub type Result<T> = std::result::Result<T, ReactError>;
