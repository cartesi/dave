// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

#![doc = include_str!("../README.md")]

pub mod configuration;
pub mod errors;

pub mod hash;
pub mod machine;

// TODO: review
pub mod log;
pub mod proof;

mod constants;
mod utils;

pub use constants::*;
pub use machine::Machine;

// Reexport inner cartesi-machine-sys
pub use cartesi_machine_sys;
