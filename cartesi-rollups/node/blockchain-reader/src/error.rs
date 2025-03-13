// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{contract::Error as ContractError, transports::http::reqwest::Url};
use std::str::FromStr;
use thiserror::Error;

use rollups_state_manager::StateManager;

#[derive(Error, Debug)]
pub struct ProviderErrors(pub Vec<ContractError>);

impl std::fmt::Display for ProviderErrors {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Provider error: {:?}", self.0)
    }
}

#[derive(Error, Debug)]
pub enum BlockchainReaderError<SM: StateManager> {
    #[error(transparent)]
    Providers {
        #[from]
        source: ProviderErrors,
    },

    #[error("Parse error: {0}")]
    ParseError(<Url as FromStr>::Err),

    #[error("State manager error: {0}")]
    StateManagerError(<SM as StateManager>::Error),
}

pub type Result<T, SM> = std::result::Result<T, BlockchainReaderError<SM>>;
