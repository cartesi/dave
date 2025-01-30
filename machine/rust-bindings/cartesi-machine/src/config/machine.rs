// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MachineConfig {
    pub processor: ProcessorConfig,
    pub ram: RAMConfig,
    pub dtb: DTBConfig,
    pub flash_drive: FlashDriveConfigs,
    pub tlb: TLBConfig,
    pub clint: CLINTConfig,
    pub plic: PLICConfig,
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
    pub x0: u64,
    pub x1: u64,
    pub x2: u64,
    pub x3: u64,
    pub x4: u64,
    pub x5: u64,
    pub x6: u64,
    pub x7: u64,
    pub x8: u64,
    pub x9: u64,
    pub x10: u64,
    pub x11: u64,
    pub x12: u64,
    pub x13: u64,
    pub x14: u64,
    pub x15: u64,
    pub x16: u64,
    pub x17: u64,
    pub x18: u64,
    pub x19: u64,
    pub x20: u64,
    pub x21: u64,
    pub x22: u64,
    pub x23: u64,
    pub x24: u64,
    pub x25: u64,
    pub x26: u64,
    pub x27: u64,
    pub x28: u64,
    pub x29: u64,
    pub x30: u64,
    pub x31: u64,
    pub f0: u64,
    pub f1: u64,
    pub f2: u64,
    pub f3: u64,
    pub f4: u64,
    pub f5: u64,
    pub f6: u64,
    pub f7: u64,
    pub f8: u64,
    pub f9: u64,
    pub f10: u64,
    pub f11: u64,
    pub f12: u64,
    pub f13: u64,
    pub f14: u64,
    pub f15: u64,
    pub f16: u64,
    pub f17: u64,
    pub f18: u64,
    pub f19: u64,
    pub f20: u64,
    pub f21: u64,
    pub f22: u64,
    pub f23: u64,
    pub f24: u64,
    pub f25: u64,
    pub f26: u64,
    pub f27: u64,
    pub f28: u64,
    pub f29: u64,
    pub f30: u64,
    pub f31: u64,
    pub pc: u64,
    pub fcsr: u64,
    pub mvendorid: u64,
    pub marchid: u64,
    pub mimpid: u64,
    pub mcycle: u64,
    pub icycleinstret: u64,
    pub mstatus: u64,
    pub mtvec: u64,
    pub mscratch: u64,
    pub mepc: u64,
    pub mcause: u64,
    pub mtval: u64,
    pub misa: u64,
    pub mie: u64,
    pub mip: u64,
    pub medeleg: u64,
    pub mideleg: u64,
    pub mcounteren: u64,
    pub menvcfg: u64,
    pub stvec: u64,
    pub sscratch: u64,
    pub sepc: u64,
    pub scause: u64,
    pub stval: u64,
    pub satp: u64,
    pub scounteren: u64,
    pub senvcfg: u64,
    pub ilrsc: u64,
    pub iprv: u64,
    #[serde(rename = "iflags_X")]
    pub iflags_x: u64,
    #[serde(rename = "iflags_Y")]
    pub iflags_y: u64,
    #[serde(rename = "iflags_H")]
    pub iflags_h: u64,
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
    pub image_filename: PathBuf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DTBConfig {
    pub bootargs: String,
    pub init: String,
    pub entrypoint: String,
    pub image_filename: PathBuf,
}

impl Default for DTBConfig {
    fn default() -> Self {
        default_config().dtb
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemoryRangeConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<u64>,
    pub image_filename: PathBuf,
    pub shared: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CmioBufferConfig {
    pub image_filename: PathBuf,
    pub shared: bool,
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TLBConfig {
    pub image_filename: PathBuf,
}

impl Default for TLBConfig {
    fn default() -> Self {
        default_config().tlb
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CLINTConfig {
    pub mtimecmp: u64,
}

impl Default for CLINTConfig {
    fn default() -> Self {
        default_config().clint
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PLICConfig {
    pub girqpend: u64,
    pub girqsrvd: u64,
}

impl Default for PLICConfig {
    fn default() -> Self {
        default_config().plic
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HTIFConfig {
    pub fromhost: u64,
    pub tohost: u64,
    pub console_getchar: bool,
    pub yield_manual: bool,
    pub yield_automatic: bool,
}

impl Default for HTIFConfig {
    fn default() -> Self {
        default_config().htif
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchProcessorConfig {
    pub x0: u64,
    pub x1: u64,
    pub x2: u64,
    pub x3: u64,
    pub x4: u64,
    pub x5: u64,
    pub x6: u64,
    pub x7: u64,
    pub x8: u64,
    pub x9: u64,
    pub x10: u64,
    pub x11: u64,
    pub x12: u64,
    pub x13: u64,
    pub x14: u64,
    pub x15: u64,
    pub x16: u64,
    pub x17: u64,
    pub x18: u64,
    pub x19: u64,
    pub x20: u64,
    pub x21: u64,
    pub x22: u64,
    pub x23: u64,
    pub x24: u64,
    pub x25: u64,
    pub x26: u64,
    pub x27: u64,
    pub x28: u64,
    pub x29: u64,
    pub x30: u64,
    pub x31: u64,
    pub pc: u64,
    pub cycle: u64,
    pub halt_flag: bool,
}

impl Default for UarchProcessorConfig {
    fn default() -> Self {
        default_config().uarch.processor
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchRAMConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<u64>,
    pub image_filename: PathBuf,
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
