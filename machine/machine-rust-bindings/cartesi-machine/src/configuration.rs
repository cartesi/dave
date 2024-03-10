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

/// CmIo configuration
#[derive(Debug, Clone)]
pub struct CmIoConfig {
    /// Represents whether the rest of the struct have been filled
    pub has_value: bool,
    /// RX buffer memory range
    pub rx_buffer: MemoryRangeConfig,
    /// TX buffer memory range
    pub tx_buffer: MemoryRangeConfig,
}

impl From<CmIoConfig> for cartesi_machine_sys::cm_cmio_config {
    fn from(config: CmIoConfig) -> Self {
        Self {
            has_value: config.has_value,
            rx_buffer: config.rx_buffer.into(),
            tx_buffer: config.tx_buffer.into(),
        }
    }
}

impl From<cartesi_machine_sys::cm_cmio_config> for CmIoConfig {
    fn from(config: cartesi_machine_sys::cm_cmio_config) -> Self {
        Self {
            has_value: config.has_value,
            rx_buffer: config.rx_buffer.into(),
            tx_buffer: config.tx_buffer.into(),
        }
    }
}

/// Uarch RAM configuration
#[derive(Debug, Clone)]
pub struct UarchRamConfig {
    /// RAM image file name
    pub image_filename: Option<String>,
}

impl From<UarchRamConfig> for cartesi_machine_sys::cm_uarch_ram_config {
    fn from(config: UarchRamConfig) -> Self {
        Self {
            image_filename: to_cstr(config.image_filename),
        }
    }
}

impl From<cartesi_machine_sys::cm_uarch_ram_config> for UarchRamConfig {
    fn from(config: cartesi_machine_sys::cm_uarch_ram_config) -> Self {
        Self {
            image_filename: from_cstr(config.image_filename),
        }
    }
}

/// Uarch Processor configuration
#[derive(Debug, Clone)]
#[repr(C)]
pub struct UarchProcessorConfig {
    /// General purpose registers
    pub x: [u64; 32usize],
    /// Program counter
    pub pc: u64,
    /// Machine cycle
    pub cycle: u64,
    /// Halt flag
    pub halt_flag: bool,
}

impl From<UarchProcessorConfig> for cartesi_machine_sys::cm_uarch_processor_config {
    fn from(config: UarchProcessorConfig) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

impl From<cartesi_machine_sys::cm_uarch_processor_config> for UarchProcessorConfig {
    fn from(config: cartesi_machine_sys::cm_uarch_processor_config) -> Self {
        unsafe { std::mem::transmute(config) }
    }
}

/// Uarch configuration
#[derive(Debug, Clone)]
pub struct UarchConfig {
    /// Processor configuration
    pub processor: UarchProcessorConfig,
    /// RAM configuration
    pub ram: UarchRamConfig,
}

impl From<UarchConfig> for cartesi_machine_sys::cm_uarch_config {
    fn from(config: UarchConfig) -> Self {
        Self {
            processor: config.processor.into(),
            ram: config.ram.into(),
        }
    }
}

impl From<cartesi_machine_sys::cm_uarch_config> for UarchConfig {
    fn from(config: cartesi_machine_sys::cm_uarch_config) -> Self {
        Self {
            processor: config.processor.into(),
            ram: config.ram.into(),
        }
    }
}

/// Machine configuration
#[derive(Debug, Clone)]
pub struct MachineConfig {
    /// Processor configuration
    pub processor: ProcessorConfig,
    /// RAM configuration
    pub ram: RamConfig,
    /// DTB configuration
    pub dtb: DtbConfig,
    /// Flash drive configuration
    pub flash_drive: Vec<MemoryRangeConfig>,
    /// TLB configuration
    pub tlb: TlbConfig,
    /// CLint configuration
    pub clint: ClintConfig,
    /// Htif configuration
    pub htif: HtifConfig,
    /// CmIo configuration
    pub cmio: CmIoConfig,
    /// Uarch configuration
    pub uarch: UarchConfig,
}

impl From<MachineConfig> for OwnedMachineConfig {
    fn from(config: MachineConfig) -> Self {
        let count = config.flash_drive.len();
        let leaked_entry = Box::leak(
            config
                .flash_drive
                .into_iter()
                .map(|x| x.into())
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        );
        let entry: *mut cartesi_machine_sys::cm_memory_range_config = leaked_entry.as_mut_ptr();
        let flash_drive = cartesi_machine_sys::cm_memory_range_config_array { entry, count };

        let config = cartesi_machine_sys::cm_machine_config {
            processor: config.processor.into(),
            ram: config.ram.into(),
            dtb: config.dtb.into(),
            flash_drive,
            tlb: config.tlb.into(),
            clint: config.clint.into(),
            htif: config.htif.into(),
            cmio: config.cmio.into(),
            uarch: config.uarch.into(),
        };

        Self(config)
    }
}

impl From<cartesi_machine_sys::cm_machine_config> for MachineConfig {
    fn from(value: cartesi_machine_sys::cm_machine_config) -> Self {
        Self {
            processor: value.processor.into(),
            ram: value.ram.into(),
            dtb: value.dtb.into(),
            flash_drive: unsafe {
                std::slice::from_raw_parts(
                    value.flash_drive.entry,
                    value.flash_drive.count as usize,
                )
                .into_iter()
                .map(|x| x.clone().into())
                .collect()
            },
            tlb: value.tlb.into(),
            clint: value.clint.into(),
            htif: value.htif.into(),
            cmio: value.cmio.into(),
            uarch: value.uarch.into(),
        }
    }
}

impl Default for MachineConfig {
    fn default() -> Self {
        unsafe {
            let raw_config = cartesi_machine_sys::cm_new_default_machine_config();
            let config = MachineConfig::from(*raw_config);
            cartesi_machine_sys::cm_delete_machine_config(raw_config);
            config
        }
    }
}

/// A machine configuration that is owned by Rust and should be dropped in another way.
pub struct OwnedMachineConfig(cartesi_machine_sys::cm_machine_config);

impl AsRef<cartesi_machine_sys::cm_machine_config> for OwnedMachineConfig {
    fn as_ref(&self) -> &cartesi_machine_sys::cm_machine_config {
        &self.0
    }
}

impl Drop for OwnedMachineConfig {
    fn drop(&mut self) {
        free_cstr(self.0.ram.image_filename);
        free_cstr(self.0.dtb.bootargs);
        free_cstr(self.0.dtb.init);
        free_cstr(self.0.dtb.entrypoint);
        free_cstr(self.0.dtb.image_filename);
        free_cstr(self.0.tlb.image_filename);
        free_cstr(self.0.cmio.rx_buffer.image_filename);
        free_cstr(self.0.cmio.tx_buffer.image_filename);
        free_cstr(self.0.uarch.ram.image_filename);

        unsafe {
            drop(Box::from_raw(std::slice::from_raw_parts_mut(
                self.0.flash_drive.entry,
                self.0.flash_drive.count as usize,
            )))
        }
    }
}

#[derive(Debug, Default, Clone)]
#[repr(C)]
pub struct ConcurrencyRuntimeConfig {
    pub update_merkle_tree: u64,
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
    pub no_console_putchar: bool,
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
