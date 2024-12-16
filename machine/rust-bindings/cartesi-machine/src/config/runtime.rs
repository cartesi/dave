// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ConcurrencyRuntimeConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_merkle_tree: Option<u64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HTIFRuntimeConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub no_console_putchar: Option<bool>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct RuntimeConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub concurrency: Option<ConcurrencyRuntimeConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub htif: Option<HTIFRuntimeConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_root_hash_check: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_root_hash_store: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_version_check: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_yield: Option<bool>,
}
