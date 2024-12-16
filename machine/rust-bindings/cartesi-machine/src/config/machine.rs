// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MachineConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processor: Option<ProcessorConfig>,
    pub ram: RAMConfig,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dtb: Option<DTBConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub flash_drive: Option<FlashDriveConfigs>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tlb: Option<TLBConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clint: Option<CLINTConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plic: Option<PLICConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub htif: Option<HTIFConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uarch: Option<UarchConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmio: Option<CmioConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub virtio: Option<VirtIOConfigs>,
}

impl Default for MachineConfig {
    fn default() -> Self {
        crate::machine::Machine::default_config().expect("failed to get default config")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProcessorConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x0: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x1: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x2: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x3: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x4: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x5: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x6: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x7: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x8: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x9: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x10: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x11: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x12: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x13: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x14: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x15: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x16: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x17: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x18: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x19: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x20: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x21: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x22: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x23: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x24: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x25: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x26: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x27: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x28: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x29: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x30: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x31: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f0: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f1: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f2: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f3: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f4: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f5: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f6: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f7: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f8: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f9: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f10: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f11: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f12: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f13: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f14: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f15: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f16: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f17: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f18: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f19: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f20: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f21: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f22: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f23: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f24: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f25: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f26: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f27: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f28: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f29: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f30: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub f31: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pc: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fcsr: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mvendorid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub marchid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mimpid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mcycle: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icycleinstret: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mstatus: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtvec: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mscratch: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mepc: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mcause: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtval: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub misa: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mie: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mip: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub medeleg: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mideleg: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mcounteren: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub menvcfg: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stvec: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sscratch: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sepc: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scause: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stval: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub satp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scounteren: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub senvcfg: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ilrsc: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iprv: Option<u64>,
    #[serde(rename = "iflags_X")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iflags_x: Option<u64>,
    #[serde(rename = "iflags_Y")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iflags_y: Option<u64>,
    #[serde(rename = "iflags_H")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iflags_h: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iunrep: Option<u64>,
}

impl Default for ProcessorConfig {
    fn default() -> Self {
        MachineConfig::default()
            .processor
            .expect("`processor` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RAMConfig {
    pub length: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
}

impl Default for RAMConfig {
    fn default() -> Self {
        MachineConfig::default().ram
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DTBConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bootargs: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub init: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entrypoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
}

impl Default for DTBConfig {
    fn default() -> Self {
        MachineConfig::default()
            .dtb
            .expect("`dtb` field should not be empty")
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemoryRangeConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shared: Option<bool>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CmioBufferConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shared: Option<bool>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct VirtIOHostfwd {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_udp: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host_ip: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest_ip: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host_port: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest_port: Option<u64>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostfwd: Option<VirtIOHostfwdArray>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iface: Option<String>,
}

pub type FlashDriveConfigs = Vec<MemoryRangeConfig>;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TLBConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
}

impl Default for TLBConfig {
    fn default() -> Self {
        MachineConfig::default()
            .tlb
            .expect("`tlb` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CLINTConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtimecmp: Option<u64>,
}

impl Default for CLINTConfig {
    fn default() -> Self {
        MachineConfig::default()
            .clint
            .expect("`clint` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PLICConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub girqpend: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub girqsrvd: Option<u64>,
}

impl Default for PLICConfig {
    fn default() -> Self {
        MachineConfig::default()
            .plic
            .expect("`plic` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HTIFConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fromhost: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tohost: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub console_getchar: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yield_manual: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yield_automatic: Option<bool>,
}

impl Default for HTIFConfig {
    fn default() -> Self {
        MachineConfig::default()
            .htif
            .expect("`htif` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchProcessorConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x0: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x1: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x2: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x3: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x4: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x5: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x6: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x7: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x8: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x9: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x10: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x11: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x12: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x13: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x14: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x15: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x16: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x17: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x18: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x19: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x20: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x21: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x22: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x23: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x24: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x25: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x26: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x27: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x28: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x29: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x30: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x31: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pc: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub halt_flag: Option<bool>,
}

impl Default for UarchProcessorConfig {
    fn default() -> Self {
        MachineConfig::default()
            .uarch
            .expect("`uarch` field should not be empty")
            .processor
            .expect("`uarch.processor` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchRAMConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_filename: Option<PathBuf>,
}

impl Default for UarchRAMConfig {
    fn default() -> Self {
        MachineConfig::default()
            .uarch
            .expect("`uarch` field should not be empty")
            .ram
            .expect("`uarch.ram` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UarchConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processor: Option<UarchProcessorConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ram: Option<UarchRAMConfig>,
}

impl Default for UarchConfig {
    fn default() -> Self {
        MachineConfig::default()
            .uarch
            .expect("`uarch` field should not be empty")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CmioConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rx_buffer: Option<CmioBufferConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx_buffer: Option<CmioBufferConfig>,
}

impl Default for CmioConfig {
    fn default() -> Self {
        MachineConfig::default()
            .cmio
            .expect("`plic` field should not be empty")
    }
}

pub type VirtIOConfigs = Vec<VirtIODeviceConfig>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_configs() {
        MachineConfig::default();
        ProcessorConfig::default();
        RAMConfig::default();
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
