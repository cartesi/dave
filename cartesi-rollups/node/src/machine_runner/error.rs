// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::merkle::DigestError;
use crate::storage::StorageError;
use cartesi_machine::error::MachineError;

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

    // The engine's verbs (collect, the stf) speak anyhow; geometry
    // violations stay panics per the stf module doc.
    #[error(transparent)]
    Engine {
        #[from]
        source: anyhow::Error,
    },

    #[error(transparent)]
    StateManagerError {
        #[from]
        source: StorageError,
    },
}

pub type Result<T> = std::result::Result<T, MachineRunnerError>;
