//! Configuration structures for the Cartesi Machine.

use crate::ffi::{free_cstr, from_cstr, to_cstr};

/// Memory range configuration
#[derive(Debug, Clone)]
pub struct MemoryRangeConfig {
    /// Memory range start position
    pub start: u64,
    /// Memory range length
    pub length: u64,
    /// Target changes to range affect image file?
    pub shared: bool,
    /// Memory range image file name
    pub image_filename: Option<String>,
}

impl From<MemoryRangeConfig> for cartesi_machine_sys::cm_memory_range_config {
    fn from(config: MemoryRangeConfig) -> Self {
        Self {
            start: config.start,
            length: config.length,
            shared: config.shared,
            image_filename: to_cstr(config.image_filename),
        }
    }
}

impl From<cartesi_machine_sys::cm_memory_range_config> for MemoryRangeConfig {
    fn from(config: cartesi_machine_sys::cm_memory_range_config) -> Self {
        Self {
            start: config.start,
            length: config.length,
            shared: config.shared,
            image_filename: from_cstr(config.image_filename),
        }
    }
}

/// Htif configuration
#[derive(Debug, Clone)]
#[repr(C)]
pub struct HtifConfig {
    /// Value of fromhost CSR
    pub fromhost: u64,
    /// Value of tohost CSR
    pub tohost: u64,
    /// Make console getchar available?
    pub console_getchar: bool,
    /// Make yield manual available?
    pub yield_manual: bool,
    /// Make yield automatic available?
    pub yield_automatic: bool,
}

impl From<HtifConfig> for cartesi_machine_sys::cm_htif_config {
    fn from(config: HtifConfig) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

impl From<cartesi_machine_sys::cm_htif_config> for HtifConfig {
    fn from(config: cartesi_machine_sys::cm_htif_config) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

#[derive(Debug, Default, Clone)]
#[repr(C)]
pub struct ConcurrencyRuntimeConfig {
    update_merkle_tree: u64,
}

impl From<ConcurrencyRuntimeConfig> for cartesi_machine_sys::cm_concurrency_runtime_config {
    fn from(config: ConcurrencyRuntimeConfig) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

impl From<cartesi_machine_sys::cm_concurrency_runtime_config> for ConcurrencyRuntimeConfig {
    fn from(config: cartesi_machine_sys::cm_concurrency_runtime_config) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

#[derive(Debug, Default, Clone)]
#[repr(C)]
pub struct HtifRuntimeConfig {
    no_console_putchar: bool,
}

impl From<HtifRuntimeConfig> for cartesi_machine_sys::cm_htif_runtime_config {
    fn from(config: HtifRuntimeConfig) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

impl From<cartesi_machine_sys::cm_htif_runtime_config> for HtifRuntimeConfig {
    fn from(config: cartesi_machine_sys::cm_htif_runtime_config) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

#[derive(Debug, Default, Clone)]
#[repr(C)]
pub struct RuntimeConfig {
    pub concurrency: ConcurrencyRuntimeConfig,
    pub htif: HtifRuntimeConfig,
    pub skip_root_hash_check: bool,
    pub skip_root_hash_store: bool,
    pub skip_version_check: bool,
    pub soft_yield: bool,
}

impl From<RuntimeConfig> for cartesi_machine_sys::cm_machine_runtime_config {
    fn from(config: RuntimeConfig) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

impl From<cartesi_machine_sys::cm_machine_runtime_config> for RuntimeConfig {
    fn from(config: cartesi_machine_sys::cm_machine_runtime_config) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

pub fn free_cm_memory_range_config_cstr(config: &mut cartesi_machine_sys::cm_memory_range_config) {
    free_cstr(config.image_filename);
}