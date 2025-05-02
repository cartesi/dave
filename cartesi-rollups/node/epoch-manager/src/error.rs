// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_prt_core::strategy::error::ReactError;

use alloy::contract::Error as AlloyContractError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum EpochManagerError {
    #[error(transparent)]
    AlloyContract {
        #[from]
        source: AlloyContractError,
    },

    #[error(transparent)]
    React {
        #[from]
        source: ReactError,
    },

    #[error(transparent)]
    StateManagerError {
        #[from]
        source: rollups_state_manager::StateAccessError,
    },
}

pub type Result<T> = std::result::Result<T, EpochManagerError>;
