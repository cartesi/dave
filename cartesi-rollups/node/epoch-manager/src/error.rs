// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::contract::Error as AlloyContractError;

use cartesi_prt_core::strategy::error::ReactError;
use rollups_state_manager::StateManager;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum EpochManagerError<SM: StateManager> {
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

    #[error("State manager error: {0}")]
    StateManagerError(<SM as StateManager>::Error),
}

pub type Result<T, SM> = std::result::Result<T, EpochManagerError<SM>>;
