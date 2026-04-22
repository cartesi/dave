// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Rust mirror of `cartesi::machine_config` and friends from the v0.20
//! cartesi-machine C++ API. The field names and nesting match the JSON
//! emitted by `cm_get_default_config` / `cm_get_initial_config` and consumed
//! by `cm_create_new`.
//!
//! Invariants this module tries to enforce:
//!
//! 1. **Exact shape match with the C++ side.** Every struct carries
//!    `#[serde(deny_unknown_fields)]` so that a future emulator release that
//!    adds or renames a field causes a *loud* deserialization failure rather
//!    than silent data loss.
//! 2. **No speculative `#[serde(default)]`.** The C++ `to_json` functions
//!    always emit every field, so missing fields on deserialize indicate a
//!    schema break, not a tolerable omission. Defaults are only applied on
//!    types the user *constructs* from scratch (via `Default::default()`),
//!    not on fields that participate in JSON round-trips.
//! 3. **Round-trip equality.** `serde_json::from_str::<MachineConfig>(raw) ->
//!    serde_json::to_value` must equal `serde_json::from_str::<Value>(raw)`
//!    for any JSON produced by the C library. Verified by
//!    `test_default_config_json_roundtrip`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Backing store
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::backing_store_config`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BackingStoreConfig {
    pub shared: bool,
    pub create: bool,
    pub truncate: bool,
    pub data_filename: PathBuf,
    pub dht_filename: PathBuf,
    pub dpt_filename: PathBuf,
}

/// Mirror of C++ `cartesi::backing_store_config_only`. Used for memory
/// regions that have no extra per-range config (pmas, uarch ram, cmio rx/tx).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BackingStoreConfigOnly {
    pub backing_store: BackingStoreConfig,
}

// ---------------------------------------------------------------------------
// Register substructures (all nested inside RegistersConfig)
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::iflags_state`. The field names in JSON are the
/// uppercase single letters `X`, `Y`, `H`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct IFlagsConfig {
    #[serde(rename = "X")]
    pub x: u64,
    #[serde(rename = "Y")]
    pub y: u64,
    #[serde(rename = "H")]
    pub h: u64,
}

/// Mirror of C++ `cartesi::clint_state`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CLINTConfig {
    pub mtimecmp: u64,
}

/// Mirror of C++ `cartesi::plic_state`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PLICConfig {
    pub girqpend: u64,
    pub girqsrvd: u64,
}

/// Mirror of C++ `cartesi::htif_state`. These are the five HTIF CSRs; the
/// old Rust binding used a different HTIF-runtime struct with feature flags
/// (`console_getchar`, `yield_manual`, `yield_automatic`), which belong to
/// `RuntimeConfig`, not `MachineConfig`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HTIFConfig {
    pub fromhost: u64,
    pub tohost: u64,
    pub ihalt: u64,
    pub iconsole: u64,
    pub iyield: u64,
}

/// Mirror of C++ `cartesi::registers_state`. This is the object emitted at
/// `processor.registers` in the config JSON.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RegistersConfig {
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
    pub iflags: IFlagsConfig,
    pub iunrep: u64,
    pub clint: CLINTConfig,
    pub plic: PLICConfig,
    pub htif: HTIFConfig,
}

// ---------------------------------------------------------------------------
// Processor
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::processor_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ProcessorConfig {
    pub registers: RegistersConfig,
    pub backing_store: BackingStoreConfig,
}

impl Default for ProcessorConfig {
    fn default() -> Self {
        library_default().processor
    }
}

// ---------------------------------------------------------------------------
// RAM and DTB
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::ram_config`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RAMConfig {
    pub length: u64,
    pub backing_store: BackingStoreConfig,
}

/// Mirror of C++ `cartesi::dtb_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DTBConfig {
    pub bootargs: String,
    pub init: String,
    pub entrypoint: String,
    pub backing_store: BackingStoreConfig,
}

impl Default for DTBConfig {
    fn default() -> Self {
        library_default().dtb
    }
}

// ---------------------------------------------------------------------------
// Memory range / flash drive
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::memory_range_config`. The C++ side uses the
/// sentinel `UINT64_MAX` for "auto-detect" on `start`/`length`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct MemoryRangeConfig {
    pub start: u64,
    pub length: u64,
    pub read_only: bool,
    pub backing_store: BackingStoreConfig,
}

impl Default for MemoryRangeConfig {
    /// Defaults match the C++ `memory_range_config` in-struct initializers:
    /// `start` and `length` are `UINT64_MAX` to mean "auto-detect".
    fn default() -> Self {
        Self {
            start: u64::MAX,
            length: u64::MAX,
            read_only: false,
            backing_store: BackingStoreConfig::default(),
        }
    }
}

pub type FlashDriveConfigs = Vec<MemoryRangeConfig>;

// ---------------------------------------------------------------------------
// CMIO
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::cmio_config`. Both buffers are
/// `backing_store_config_only`.
pub type CmioBufferConfig = BackingStoreConfigOnly;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CmioConfig {
    pub rx_buffer: CmioBufferConfig,
    pub tx_buffer: CmioBufferConfig,
}

// ---------------------------------------------------------------------------
// VirtIO
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::virtio_hostfwd_config`. Note that `host_port`
/// and `guest_port` are `uint16_t` on the C++ side.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct VirtIOHostfwdConfig {
    pub is_udp: bool,
    pub host_ip: u64,
    pub guest_ip: u64,
    pub host_port: u16,
    pub guest_port: u16,
}

pub type VirtIOHostfwdArray = Vec<VirtIOHostfwdConfig>;

/// Mirror of C++ `cartesi::virtio_device_config` (a `std::variant`). The
/// JSON representation uses `"type"` as the discriminator, matching the
/// `to_json(virtio_device_config)` implementation.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum VirtIODeviceConfig {
    Console,
    P9fs {
        tag: String,
        host_directory: String,
    },
    #[serde(rename = "net-user")]
    NetUser {
        hostfwd: VirtIOHostfwdArray,
    },
    #[serde(rename = "net-tuntap")]
    NetTuntap {
        iface: String,
    },
}

impl Default for VirtIODeviceConfig {
    fn default() -> Self {
        VirtIODeviceConfig::Console
    }
}

pub type VirtIOConfigs = Vec<VirtIODeviceConfig>;

// ---------------------------------------------------------------------------
// PMAS
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::pmas_config` (alias for `backing_store_config_only`).
pub type PmasConfig = BackingStoreConfigOnly;

// ---------------------------------------------------------------------------
// Uarch
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::uarch_registers_state`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct UarchRegistersConfig {
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
    /// `uint64_t` on the C++ side (shadow-uarch-state.h), not a C++ `bool`.
    /// Used as a boolean flag (0 = not halted, non-zero = halted), but the
    /// wire representation is an integer.
    pub halt_flag: u64,
}

/// Mirror of C++ `cartesi::uarch_processor_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct UarchProcessorConfig {
    pub registers: UarchRegistersConfig,
    pub backing_store: BackingStoreConfig,
}

impl Default for UarchProcessorConfig {
    fn default() -> Self {
        library_default().uarch.processor
    }
}

/// Mirror of C++ `cartesi::uarch_ram_config` (alias for
/// `backing_store_config_only`).
pub type UarchRAMConfig = BackingStoreConfigOnly;

/// Mirror of C++ `cartesi::uarch_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct UarchConfig {
    pub processor: UarchProcessorConfig,
    pub ram: UarchRAMConfig,
}

impl Default for UarchConfig {
    fn default() -> Self {
        library_default().uarch
    }
}

// ---------------------------------------------------------------------------
// Hash tree
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::hash_function_type`. Serialized as a lower-case
/// string (`"keccak256"` / `"sha256"`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HashFunctionType {
    #[default]
    Keccak256,
    Sha256,
}

/// Mirror of C++ `cartesi::hash_tree_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HashTreeConfig {
    pub shared: bool,
    pub create: bool,
    pub sht_filename: PathBuf,
    pub phtc_filename: PathBuf,
    pub phtc_size: u64,
    pub hash_function: HashFunctionType,
}

impl Default for HashTreeConfig {
    fn default() -> Self {
        library_default().hash_tree
    }
}

// ---------------------------------------------------------------------------
// Top-level machine config
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::machine_config`. The field ordering matches the
/// order in which `to_json(machine_config)` emits them on the C++ side.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct MachineConfig {
    pub processor: ProcessorConfig,
    pub ram: RAMConfig,
    pub dtb: DTBConfig,
    pub flash_drive: FlashDriveConfigs,
    pub virtio: VirtIOConfigs,
    pub cmio: CmioConfig,
    pub pmas: PmasConfig,
    pub uarch: UarchConfig,
    pub hash_tree: HashTreeConfig,
}

impl MachineConfig {
    /// Starts from the library's default config and overrides only the RAM
    /// block. Useful for the common case where callers want the emulator's
    /// baseline configuration plus a specific RAM image.
    pub fn new_with_ram(ram: RAMConfig) -> Self {
        let mut cfg = library_default();
        cfg.ram = ram;
        cfg
    }
}

/// Fetches the emulator's built-in default config via `cm_get_default_config`.
/// All `Default` impls in this file delegate here rather than synthesizing
/// zeros in Rust, because C-side defaults carry non-trivial values like
/// `mvendorid`, `marchid`, initial `misa`, and the DTB `bootargs` string.
fn library_default() -> MachineConfig {
    crate::machine::Machine::default_config()
        .expect("failed to get default machine config from cartesi-machine library")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machine::Machine;
    use crate::{EXPECTED_EMULATOR_VERSION, format_emulator_version};

    /// Guardrail: the linked `libcartesi` must report the exact version these
    /// bindings were written against. If this fails after an emulator bump,
    /// update `EXPECTED_EMULATOR_VERSION` in `lib.rs` and rerun the config
    /// round-trip tests to re-confirm the schema.
    #[test]
    fn test_emulator_version_pin() {
        let linked = Machine::version();
        assert_eq!(
            linked,
            EXPECTED_EMULATOR_VERSION,
            "cartesi-machine bindings were written for emulator version {}, but libcartesi reports {}. \
             Update EXPECTED_EMULATOR_VERSION after verifying the config schema still matches.",
            format_emulator_version(EXPECTED_EMULATOR_VERSION),
            format_emulator_version(linked),
        );
    }

    #[test]
    fn test_default_configs() {
        library_default();
        ProcessorConfig::default();
        DTBConfig::default();
        MemoryRangeConfig::default();
        CLINTConfig::default();
        PLICConfig::default();
        HTIFConfig::default();
        UarchProcessorConfig::default();
        UarchConfig::default();
        CmioConfig::default();
        HashTreeConfig::default();
    }

    /// Guardrail against silent schema drift between the Rust bindings and
    /// the C++ `cartesi::machine_config`. Loads the default config as raw
    /// JSON, deserializes it into `MachineConfig`, re-serializes, and
    /// asserts structural equality with the original JSON.
    ///
    /// If this test fails after an emulator bump, do NOT add
    /// `#[serde(default)]` to make it pass — the right fix is to update
    /// this file's structs to match whatever the C++ side now emits.
    #[test]
    fn test_default_config_json_roundtrip() {
        let raw_json =
            Machine::default_config_raw_json().expect("failed to fetch raw default config JSON");

        let original: serde_json::Value = serde_json::from_str(&raw_json)
            .expect("raw JSON from cm_get_default_config is not valid JSON");

        let typed: MachineConfig = serde_json::from_str(&raw_json).unwrap_or_else(|e| {
            panic!(
                "failed to deserialize cm_get_default_config JSON into MachineConfig: {e}\n\
                 (this usually means a schema drift between the emulator and these bindings)"
            );
        });

        let reserialized = serde_json::to_value(&typed).expect("re-serialization failed");

        assert_eq!(
            original, reserialized,
            "MachineConfig round-trip lost or added data. Schema drift vs the C++ side."
        );
    }

    /// Guardrail: makes sure an unknown field at the top level fails rather
    /// than being silently dropped. Regression test for the bug this
    /// refactor is fixing.
    #[test]
    fn test_unknown_field_is_rejected() {
        let raw_json =
            Machine::default_config_raw_json().expect("failed to fetch raw default config JSON");

        // Inject an unknown top-level field.
        let mut value: serde_json::Value = serde_json::from_str(&raw_json).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("something_new".to_string(), serde_json::json!(42));

        let result = serde_json::from_value::<MachineConfig>(value);
        assert!(
            result.is_err(),
            "deny_unknown_fields must reject previously-unseen top-level keys"
        );
    }
}
