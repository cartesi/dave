// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_dave_merkle::DigestError;
use cartesi_machine::error::MachineError;
use rollups_state_manager::StateAccessError;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum MachineRunnerError {
    #[error(transparent)]
    Digest {
        #[from]
        source: DigestError,
    },

    #[error(transparent)]
    IO {
        #[from]
        source: std::io::Error,
    },

    #[error(transparent)]
    Machine {
        #[from]
        source: MachineError,
    },

    #[error("Couldn't complete machine run with: `{reason}`")]
    MachineRunFail { reason: u32 },

    #[error(transparent)]
    StateManagerError {
        #[from]
        source: StateAccessError,
    },
}

pub type Result<T> = std::result::Result<T, MachineRunnerError>;
