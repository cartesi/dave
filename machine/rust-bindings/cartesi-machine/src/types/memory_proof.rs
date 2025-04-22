// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::types::{Hash, base64_decode::*};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Proof {
    pub target_address: u64,
    pub log2_target_size: u64,

    #[serde(
        deserialize_with = "deserialize_base64_32",
        serialize_with = "serialize_base64_32"
    )]
    pub target_hash: Hash,

    pub log2_root_size: u64,

    #[serde(
        deserialize_with = "deserialize_base64_32",
        serialize_with = "serialize_base64_32"
    )]
    pub root_hash: Hash,

    #[serde(
        deserialize_with = "deserialize_base64_32_array",
        serialize_with = "serialize_base64_32_array"
    )]
    pub sibling_hashes: Vec<Hash>,
}
