// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

#![doc = include_str!("../README.md")]

// Reexport inner cartesi-machine-sys
pub use cartesi_machine_sys;

pub mod configuration;
pub mod errors;

pub mod hash;
pub mod machine;

mod constants;
pub use constants::*;

// TODO: review
pub mod log;
pub mod proof;

mod utils;

use cartesi_machine_sys::{cm_cmio_config, cm_htif_config};

pub type MemoryRangeConfig = cartesi_machine_sys::cm_memory_range_config;
pub type RuntimeConfig = cartesi_machine_sys::cm_machine_runtime_config;

#[derive(Debug, Clone)]
pub struct MachineConfig {
    config: *const cartesi_machine_sys::cm_machine_config,
}

impl Drop for MachineConfig {
    fn drop(&mut self) {
        unsafe {
            cartesi_machine_sys::cm_delete_machine_config(self.config);
        };
    }
}

impl MachineConfig {
    pub fn cmio(&self) -> &cm_cmio_config {
        &unsafe { self.config.as_ref().unwrap() }.cmio
    }

    pub fn htif(&self) -> &cm_htif_config {
        &unsafe { self.config.as_ref().unwrap() }.htif
    }
}
