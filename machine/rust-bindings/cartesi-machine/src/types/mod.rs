// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod access_proof;
pub mod cmio;
pub mod memory_proof;
pub mod memory_range;

pub type Hash = cartesi_machine_sys::cm_hash;
pub type Register = cartesi_machine_sys::cm_reg;
pub type BreakReason = cartesi_machine_sys::cm_break_reason;
pub type UArchBreakReason = cartesi_machine_sys::cm_uarch_break_reason;

/// Backing-store sharing mode (`cm_sharing_mode`): where a loaded
/// machine's mutations live.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SharingMode {
    /// Fully in-memory: files are mapped privately, mutations are
    /// discarded on destroy.
    None,
    /// Per-range `shared` flags from the stored config (the emulator
    /// default; typically everything private).
    Config,
    /// Fully on-disk: every file is mapped shared, mutations land in
    /// the loaded directory as they happen. The machine holds an
    /// exclusive advisory lock on the directory's writable files for
    /// its lifetime.
    All,
}

impl From<SharingMode> for cartesi_machine_sys::cm_sharing_mode {
    fn from(mode: SharingMode) -> Self {
        match mode {
            SharingMode::None => cartesi_machine_sys::CM_SHARING_NONE,
            SharingMode::Config => cartesi_machine_sys::CM_SHARING_CONFIG,
            SharingMode::All => cartesi_machine_sys::CM_SHARING_ALL,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct LogType {
    pub annotations: bool,
    pub large_data: bool,
}

impl LogType {
    pub fn with_annotations(mut self) -> Self {
        self.annotations = true;
        self
    }

    pub fn with_large_data(mut self) -> Self {
        self.large_data = true;
        self
    }

    pub fn to_bitflag(&self) -> i32 {
        let mut ret = 0;
        if self.annotations {
            ret |= crate::constants::access_log_type::ANNOTATIONS;
        }
        if self.large_data {
            ret |= crate::constants::access_log_type::LARGE_DATA
        }
        ret.try_into().unwrap()
    }
}

mod base64_decode;
