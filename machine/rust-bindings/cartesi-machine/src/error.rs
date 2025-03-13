// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Error handling for the machine emulator

use std::fmt::Display;

pub type MachineResult<T> = Result<T, MachineError>;

/// Error returned from machine emulator C API
#[derive(Debug, Clone, thiserror::Error)]
pub struct MachineError {
    pub code: i32,
    pub message: String,
}

impl Display for MachineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Cartesi Machine error {}: {}", self.code, self.message)
    }
}
