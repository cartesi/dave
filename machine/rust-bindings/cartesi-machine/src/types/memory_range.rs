// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::Deserialize;

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryRangeDescription {
    pub start: u64,
    pub length: u64,
    pub description: Option<String>,
    pub is_memory: bool,
    pub is_device: bool,
    pub is_readable: bool,
    pub is_writeable: bool,
    pub is_executable: bool,
    pub is_read_idempotent: bool,
    pub is_write_idempotent: bool,
    pub driver_id: u64,
}

pub type MemoryRangeDescriptions = Vec<MemoryRangeDescription>;
