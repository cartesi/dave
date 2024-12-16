// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

#![doc = include_str!("../README.md")]

pub mod config;
pub mod constants;
pub mod error;
pub mod machine;
pub mod types;

pub use machine::Machine;

// Reexport inner cartesi-machine-sys
pub use cartesi_machine_sys;
