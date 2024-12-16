// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::Deserialize;

#[derive(Clone, Debug, Default, Deserialize)]
pub struct MemoryRangeDescription {
    pub start: u64,
    pub length: u64,
    pub description: Option<String>,
}

pub type MemoryRangeDescriptions = Vec<MemoryRangeDescription>;
