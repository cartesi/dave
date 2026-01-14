// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Backing store config; matches C++ backing_store_config (data_filename, etc.).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BackingStoreConfig {
    #[serde(default)]
    pub shared: bool,
    #[serde(default)]
    pub create: bool,
    #[serde(default)]
    pub truncate: bool,
    #[serde(default)]
    pub data_filename: PathBuf,
    #[serde(default)]
    pub dht_filename: PathBuf,
    #[serde(default)]
    pub dpt_filename: PathBuf,
}

/// Config with only backing_store; matches C++ backing_store_config_only.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BackingStoreConfigOnly {
    #[serde(default)]
    pub backing_store: BackingStoreConfig,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MachineConfig {
    pub processor: ProcessorConfig,
    pub ram: RAMConfig,
    pub dtb: DTBConfig,
    pub flash_drive: FlashDriveConfigs,
    #[serde(default)]
    pub tlb: TLBConfig,
    #[serde(default)]
    pub clint: CLINTConfig,
    #[serde(default)]
    pub plic: PLICConfig,
    #[serde(default)]
    pub htif: HTIFConfig,
    pub uarch: UarchConfig,
    pub cmio: CmioConfig,
    pub virtio: VirtIOConfigs,
}

impl MachineConfig {
    pub fn new_with_ram(ram: RAMConfig) -> Self {
        Self {
            processor: ProcessorConfig::default(),
            ram,
            dtb: DTBConfig::default(),
            flash_drive: FlashDriveConfigs::default(),
            tlb: TLBConfig::default(),
            clint: CLINTConfig::default(),
            plic: PLICConfig::default(),
            htif: HTIFConfig::default(),
            uarch: UarchConfig::default(),
            cmio: CmioConfig::default(),
            virtio: VirtIOConfigs::default(),
        }
    }

    pub fn processor(mut self, processor: ProcessorConfig) -> Self {
        self.processor = processor;
        self
    }

    pub fn dtb(mut self, dtb: DTBConfig) -> Self {
        self.dtb = dtb;
        self
    }

    pub fn add_flash_drive(mut self, flash_drive: MemoryRangeConfig) -> Self {
        self.flash_drive.push(flash_drive);
        self
    }

    pub fn tlb(mut self, tlb: TLBConfig) -> Self {
        self.tlb = tlb;
        self
    }

    pub fn clint(mut self, clint: CLINTConfig) -> Self {
        self.clint = clint;
        self
    }

    pub fn plic(mut self, plic: PLICConfig) -> Self {
        self.plic = plic;
        self
    }

    pub fn htif(mut self, htif: HTIFConfig) -> Self {
        self.htif = htif;
        self
    }

    pub fn uarch(mut self, uarch: UarchConfig) -> Self {
        self.uarch = uarch;
        self
    }

    pub fn cmio(mut self, cmio: CmioConfig) -> Self {
        self.cmio = cmio;
        self
    }

    pub fn add_virtio(mut self, virtio_config: VirtIODeviceConfig) -> Self {
        self.virtio.push(virtio_config);
        self
    }
}

fn default_config() -> MachineConfig {
    crate::machine::Machine::default_config().expect("failed to get default config")
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProcessorConfig {
    #[serde(default)]
    pub backing_store: BackingStoreConfig,
    #[serde(default)]
    pub x0: u64,
    #[serde(default)]
    pub x1: u64,
    #[serde(default)]
    pub x2: u64,
    #[serde(default)]
    pub x3: u64,
    #[serde(default)]
    pub x4: u64,
    #[serde(default)]
    pub x5: u64,
    #[serde(default)]
    pub x6: u64,
    #[serde(default)]
    pub x7: u64,
    #[serde(default)]
    pub x8: u64,
    #[serde(default)]
    pub x9: u64,
    #[serde(default)]
    pub x10: u64,
    #[serde(default)]
    pub x11: u64,
    #[serde(default)]
    pub x12: u64,
    #[serde(default)]
    pub x13: u64,
    #[serde(default)]
    pub x14: u64,
    #[serde(default)]
    pub x15: u64,
    #[serde(default)]
    pub x16: u64,
    #[serde(default)]
    pub x17: u64,
    #[serde(default)]
    pub x18: u64,
    #[serde(default)]
    pub x19: u64,
    #[serde(default)]
    pub x20: u64,
    #[serde(default)]
    pub x21: u64,
    #[serde(default)]
    pub x22: u64,
    #[serde(default)]
    pub x23: u64,
    #[serde(default)]
    pub x24: u64,
    #[serde(default)]
    pub x25: u64,
    #[serde(default)]
    pub x26: u64,
    #[serde(default)]
    pub x27: u64,
    #[serde(default)]
    pub x28: u64,
    #[serde(default)]
    pub x29: u64,
    #[serde(default)]
    pub x30: u64,
    #[serde(default)]
    pub x31: u64,
    #[serde(default)]
    pub f0: u64,
    #[serde(default)]
    pub f1: u64,
    #[serde(default)]
    pub f2: u64,
    #[serde(default)]
    pub f3: u64,
    #[serde(default)]
    pub f4: u64,
    #[serde(default)]
    pub f5: u64,
    #[serde(default)]
    pub f6: u64,
    #[serde(default)]
    pub f7: u64,
    #[serde(default)]
    pub f8: u64,
    #[serde(default)]
    pub f9: u64,
    #[serde(default)]
    pub f10: u64,
    #[serde(default)]
    pub f11: u64,
    #[serde(default)]
    pub f12: u64,
    #[serde(default)]
    pub f13: u64,
    #[serde(default)]
    pub f14: u64,
    #[serde(default)]
    pub f15: u64,
    #[serde(default)]
    pub f16: u64,
    #[serde(default)]
    pub f17: u64,
    #[serde(default)]
    pub f18: u64,
    #[serde(default)]
    pub f19: u64,
    #[serde(default)]
    pub f20: u64,
    #[serde(default)]
    pub f21: u64,
    #[serde(default)]
    pub f22: u64,
    #[serde(default)]
    pub f23: u64,
    #[serde(default)]
    pub f24: u64,
    #[serde(default)]
    pub f25: u64,
    #[serde(default)]
    pub f26: u64,
    #[serde(default)]
    pub f27: u64,
    #[serde(default)]
    pub f28: u64,
    #[serde(default)]
    pub f29: u64,
    #[serde(default)]
    pub f30: u64,
    #[serde(default)]
    pub f31: u64,
    #[serde(default)]
    pub pc: u64,
    #[serde(default)]
    pub fcsr: u64,
    #[serde(default)]
    pub mvendorid: u64,
    #[serde(default)]
    pub marchid: u64,
    #[serde(default)]
    pub mimpid: u64,
    #[serde(default)]
    pub mcycle: u64,
    #[serde(default)]
    pub icycleinstret: u64,
    #[serde(default)]
    pub mstatus: u64,
    #[serde(default)]
    pub mtvec: u64,
    #[serde(default)]
    pub mscratch: u64,
    #[serde(default)]
    pub mepc: u64,
    #[serde(default)]
    pub mcause: u64,
    #[serde(default)]
    pub mtval: u64,
    #[serde(default)]
    pub misa: u64,
    #[serde(default)]
    pub mie: u64,
    #[serde(default)]
    pub mip: u64,
    #[serde(default)]
    pub medeleg: u64,
    #[serde(default)]
    pub mideleg: u64,
    #[serde(default)]
    pub mcounteren: u64,
    #[serde(default)]
    pub menvcfg: u64,
    #[serde(default)]
    pub stvec: u64,
    #[serde(default)]
    pub sscratch: u64,
    #[serde(default)]
    pub sepc: u64,
    #[serde(default)]
    pub scause: u64,
    #[serde(default)]
    pub stval: u64,
    #[serde(default)]
    pub satp: u64,
    #[serde(default)]
    pub scounteren: u64,
    #[serde(default)]
    pub senvcfg: u64,
    #[serde(default)]
    pub ilrsc: u64,
    #[serde(default)]
    pub iprv: u64,
    #[serde(default)]
    #[serde(rename = "iflags_X")]
    pub iflags_x: u64,
    #[serde(default)]
    #[serde(rename = "iflags_Y")]
    pub iflags_y: u64,
    #[serde(default)]
    #[serde(rename = "iflags_H")]
    pub iflags_h: u64,
    #[serde(default)]
    pub iunrep: u64,
}

impl Default for ProcessorConfig {
    fn default() -> Self {
        default_config().processor
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RAMConfig {
    pub length: u64,
    pub backing_store: BackingStoreConfig,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DTBConfig {
    pub bootargs: String,
    pub init: String,
    pub entrypoint: String,
    pub backing_store: BackingStoreConfig,
}

impl Default for DTBConfig {
    fn default() -> Self {
        default_config().dtb
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemoryRangeConfig {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub start: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub length: Option<u64>,
    #[serde(default)]
    pub read_only: bool,
    pub backing_store: BackingStoreConfig,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CmioBufferConfig {
    pub backing_store: BackingStoreConfig,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct VirtIOHostfwd {
    pub is_udp: bool,
    pub host_ip: u64,
    pub guest_ip: u64,
    pub host_port: u64,
    pub guest_port: u64,
}

pub type VirtIOHostfwdArray = Vec<VirtIOHostfwd>;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VirtIODeviceType {
    #[default]
    Console,
    P9fs,
    #[serde(rename = "net-user")]
    NetUser,
    #[serde(rename = "net-tuntap")]
    NetTuntap,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct VirtIODeviceConfig {
    pub r#type: VirtIODeviceType,
    pub tag: String,
    pub host_directory: String,
    pub hostfwd: VirtIOHostfwdArray,
    pub iface: String,
}

pub type FlashDriveConfigs = Vec<MemoryRangeConfig>;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TLBConfig {
    #[serde(default)]
    pub backing_store: BackingStoreConfig,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CLINTConfig {
    #[serde(default)]
    pub mtimecmp: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PLICConfig {
    #[serde(default)]
    pub girqpend: u64,
    #[serde(default)]
    pub girqsrvd: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HTIFConfig {
    #[serde(default)]
    pub fromhost: u64,
    #[serde(default)]
    pub tohost: u64,
    #[serde(default)]
    pub console_getchar: bool,
    #[serde(default)]
    pub yield_manual: bool,
    #[serde(default)]
    pub yield_automatic: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchProcessorConfig {
    #[serde(default)]
    pub backing_store: BackingStoreConfig,
    #[serde(default)]
    pub x0: u64,
    #[serde(default)]
    pub x1: u64,
    #[serde(default)]
    pub x2: u64,
    #[serde(default)]
    pub x3: u64,
    #[serde(default)]
    pub x4: u64,
    #[serde(default)]
    pub x5: u64,
    #[serde(default)]
    pub x6: u64,
    #[serde(default)]
    pub x7: u64,
    #[serde(default)]
    pub x8: u64,
    #[serde(default)]
    pub x9: u64,
    #[serde(default)]
    pub x10: u64,
    #[serde(default)]
    pub x11: u64,
    #[serde(default)]
    pub x12: u64,
    #[serde(default)]
    pub x13: u64,
    #[serde(default)]
    pub x14: u64,
    #[serde(default)]
    pub x15: u64,
    #[serde(default)]
    pub x16: u64,
    #[serde(default)]
    pub x17: u64,
    #[serde(default)]
    pub x18: u64,
    #[serde(default)]
    pub x19: u64,
    #[serde(default)]
    pub x20: u64,
    #[serde(default)]
    pub x21: u64,
    #[serde(default)]
    pub x22: u64,
    #[serde(default)]
    pub x23: u64,
    #[serde(default)]
    pub x24: u64,
    #[serde(default)]
    pub x25: u64,
    #[serde(default)]
    pub x26: u64,
    #[serde(default)]
    pub x27: u64,
    #[serde(default)]
    pub x28: u64,
    #[serde(default)]
    pub x29: u64,
    #[serde(default)]
    pub x30: u64,
    #[serde(default)]
    pub x31: u64,
    #[serde(default)]
    pub pc: u64,
    #[serde(default)]
    pub cycle: u64,
    #[serde(default)]
    pub halt_flag: bool,
}

impl Default for UarchProcessorConfig {
    fn default() -> Self {
        default_config().uarch.processor
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchRAMConfig {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub length: Option<u64>,
    pub backing_store: BackingStoreConfig,
}

impl Default for UarchRAMConfig {
    fn default() -> Self {
        default_config().uarch.ram
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchConfig {
    pub processor: UarchProcessorConfig,
    pub ram: UarchRAMConfig,
}

impl Default for UarchConfig {
    fn default() -> Self {
        default_config().uarch
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CmioConfig {
    pub rx_buffer: CmioBufferConfig,
    pub tx_buffer: CmioBufferConfig,
}

impl Default for CmioConfig {
    fn default() -> Self {
        default_config().cmio
    }
}

pub type VirtIOConfigs = Vec<VirtIODeviceConfig>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_configs() {
        default_config();
        ProcessorConfig::default();
        DTBConfig::default();
        TLBConfig::default();
        CLINTConfig::default();
        PLICConfig::default();
        HTIFConfig::default();
        UarchProcessorConfig::default();
        UarchRAMConfig::default();
        UarchConfig::default();
        CmioConfig::default();
    }
}
