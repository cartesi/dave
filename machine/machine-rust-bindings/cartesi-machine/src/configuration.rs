// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub type MemoryRangeConfig = cartesi_machine_sys::cm_memory_range_config;
pub type CmIoConfig = cartesi_machine_sys::cm_cmio_config;
pub type CmIoBufferConfig = cartesi_machine_sys::cm_cmio_buffer_config;
pub type HtifConfig = cartesi_machine_sys::cm_htif_config;

pub type MachineConfig = cartesi_machine_sys::cm_machine_config;

#[derive(Debug)]
pub struct MachineConfigRef {
    config: *const MachineConfig,
}

impl Drop for MachineConfigRef {
    fn drop(&mut self) {
        unsafe {
            cartesi_machine_sys::cm_delete_machine_config(self.config);
        };
    }
}

impl Default for MachineConfigRef {
    fn default() -> Self {
        let mut error_collector = crate::errors::ErrorCollector::new();
        let mut config = std::ptr::null();

        let result = unsafe {
            cartesi_machine_sys::cm_get_default_config(&mut config, error_collector.as_mut_ptr())
        };
        error_collector
            .collect(result)
            .expect("cm_get_default_config should never fail");

        Self { config }
    }
}

impl MachineConfigRef {
    pub fn try_new(
        machine: &crate::Machine,
    ) -> Result<MachineConfigRef, crate::errors::MachineError> {
        let mut error_collector = crate::errors::ErrorCollector::new();
        let mut config = std::ptr::null();

        let result = unsafe {
            cartesi_machine_sys::cm_get_initial_config(
                machine.machine,
                &mut config,
                error_collector.as_mut_ptr(),
            )
        };
        error_collector.collect(result)?;

        Ok(Self { config })
    }

    pub fn inner(&self) -> &MachineConfig {
        unsafe { self.config.as_ref().unwrap() }
    }
}

type CmRuntimeConfig = cartesi_machine_sys::cm_machine_runtime_config;

#[derive(Debug, Clone)]
pub struct RuntimeConfig {
    pub values: CmRuntimeConfig,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            values: CmRuntimeConfig {
                concurrency: cartesi_machine_sys::cm_concurrency_runtime_config {
                    update_merkle_tree: 0,
                },
                htif: cartesi_machine_sys::cm_htif_runtime_config {
                    no_console_putchar: true,
                },
                skip_root_hash_check: false,
                skip_version_check: false,
                soft_yield: false,
                skip_root_hash_store: false,
            },
        }
    }
}

impl RuntimeConfig {
    pub fn concurrency(mut self, update_merkle_tree: u64) -> Self {
        self.values.concurrency.update_merkle_tree = update_merkle_tree;
        self
    }

    pub fn no_console_putchar(mut self, no_console_putchar: bool) -> Self {
        self.values.htif.no_console_putchar = no_console_putchar;
        self
    }

    pub fn skip_root_hash_check(mut self, skip_root_hash_check: bool) -> Self {
        self.values.skip_root_hash_check = skip_root_hash_check;
        self
    }

    pub fn skip_version_check(mut self, skip_version_check: bool) -> Self {
        self.values.skip_version_check = skip_version_check;
        self
    }

    pub fn soft_yield(mut self, soft_yield: bool) -> Self {
        self.values.soft_yield = soft_yield;
        self
    }
}
