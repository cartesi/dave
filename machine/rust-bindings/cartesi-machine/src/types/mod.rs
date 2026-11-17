// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod access_proof;
pub mod cmio;
pub mod collect;
pub mod memory_proof;
pub mod memory_range;

pub type Hash = cartesi_machine_sys::cm_hash;
pub type Register = cartesi_machine_sys::cm_reg;
pub type BreakReason = cartesi_machine_sys::cm_break_reason;
pub type UArchBreakReason = cartesi_machine_sys::cm_uarch_break_reason;

/// What `remove_stored` accepts in the directory it removes
/// (`cm_remove_mode`). Either way it must hold regular files only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoveMode {
    /// An empty directory, or a loadable stored machine and no other file.
    Stored,
    /// Any regular files, such as what an interrupted store or clone left.
    Forced,
}

impl From<RemoveMode> for cartesi_machine_sys::cm_remove_mode {
    fn from(mode: RemoveMode) -> Self {
        match mode {
            RemoveMode::Stored => cartesi_machine_sys::CM_REMOVE_STORED,
            RemoveMode::Forced => cartesi_machine_sys::CM_REMOVE_FORCED,
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
