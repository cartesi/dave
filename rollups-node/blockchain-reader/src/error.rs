// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use rollups_state_manager::StateManager;

use ethers::abi::Error as AbiError;
use ethers::prelude::Http;
use ethers::providers::ProviderError;
use std::str::FromStr;
use thiserror::Error;

#[derive(Error, Debug)]
pub struct ProviderErrors(pub Vec<ProviderError>);

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

    #[error(transparent)]
    Abi {
        #[from]
        source: AbiError,
    },

    #[error("Parse error: {0}")]
    ParseError(<Http as FromStr>::Err),
    #[error("State manager error: {0}")]
    StateManagerError(<SM as StateManager>::Error),
}

pub type Result<T, SM> = std::result::Result<T, BlockchainReaderError<SM>>;
