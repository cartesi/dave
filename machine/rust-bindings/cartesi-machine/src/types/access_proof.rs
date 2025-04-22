// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::types::{Hash, base64_decode::*};
use serde::{Deserialize, Serialize};

pub type NoteArray = Vec<String>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BracketType {
    Begin,
    End,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessType {
    Read,
    Write,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Bracket {
    pub r#type: BracketType,
    pub r#where: u64,
    pub text: String,
}

pub type BracketArray = Vec<Bracket>;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Access {
    pub r#type: AccessType,
    pub address: u64,
    pub log2_size: u64,

    #[serde(
        deserialize_with = "deserialize_base64_32",
        serialize_with = "serialize_base64_32"
    )]
    pub read_hash: Hash,

    #[serde(
        deserialize_with = "deserialize_base64_vec_opt",
        serialize_with = "serialize_base64_vec_opt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub read: Option<Vec<u8>>,

    #[serde(
        deserialize_with = "deserialize_base64_32_opt",
        serialize_with = "serialize_base64_32_opt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub written_hash: Option<Hash>,

    #[serde(
        deserialize_with = "deserialize_base64_vec_opt",
        serialize_with = "serialize_base64_vec_opt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub written: Option<Vec<u8>>,

    #[serde(
        deserialize_with = "deserialize_base64_32_array_opt",
        serialize_with = "serialize_base64_32_array_opt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub sibling_hashes: Option<Vec<Hash>>,
}

pub type AccessArray = Vec<Access>;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AccessLogType {
    pub has_annotations: bool,
    pub has_large_data: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AccessLog {
    pub log_type: AccessLogType,
    pub accesses: AccessArray,
    pub notes: Option<NoteArray>,
    pub brackets: Option<BracketArray>,
}
