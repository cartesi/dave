// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_prt_core::strategy::error::ReactError;
use rollups_state_manager::StateManager;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum PRTRunnerError<SM: StateManager> {
    #[error(transparent)]
    React {
        #[from]
        source: ReactError,
    },

    #[error("State manager error: {0}")]
    StateManagerError(<SM as StateManager>::Error),
}

pub type Result<T, SM> = std::result::Result<T, PRTRunnerError<SM>>;
