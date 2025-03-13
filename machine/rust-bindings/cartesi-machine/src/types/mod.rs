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

#[derive(Clone, Debug)]
pub enum LogType {
    Annotations = crate::constants::access_log_type::ANNOTATIONS as isize,
    LargeData = crate::constants::access_log_type::LARGE_DATA as isize,
}

mod base64_decode;
