// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use crate::db::sql::error::ComputeStateAccessError;
use cartesi_machine::error::MachineError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MachineInstanceError {
    #[error(transparent)]
    MachineBindingError {
        #[from]
        source: MachineError,
    },

    #[error(transparent)]
    ComputeStateAccessError {
        #[from]
        source: ComputeStateAccessError,
    },

    #[error("Invalid hex string")]
    InvalidHexString(#[from] hex::FromHexError),
}

pub type Result<T> = std::result::Result<T, MachineInstanceError>;
