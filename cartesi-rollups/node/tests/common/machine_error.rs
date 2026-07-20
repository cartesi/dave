// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use cartesi_machine::error::MachineError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MachineInstanceError {
    #[error(transparent)]
    MachineBindingError {
        #[from]
        source: MachineError,
    },

    #[error("Invalid hex string")]
    InvalidHexString(#[from] hex::FromHexError),

    #[error("Invalid io string")]
    IOError(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, MachineInstanceError>;
