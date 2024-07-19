// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_machine::errors::MachineError;
use cartesi_prt_core::merkle::DigestError;
use rollups_state_manager::StateManager;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum MachineRunnerError<SM: StateManager> {
    #[error(transparent)]
    Digest {
        #[from]
        source: DigestError,
    },
    #[error(transparent)]
    Machine {
        #[from]
        source: MachineError,
    },

    #[error("Couldn't complete machine run with: `{reason}`")]
    MachineRunFail { reason: u32 },

    #[error("State manager error: {0}")]
    StateManagerError(<SM as StateManager>::Error),
}

pub type Result<T, SM> = std::result::Result<T, MachineRunnerError<SM>>;
