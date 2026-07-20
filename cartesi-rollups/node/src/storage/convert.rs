// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Conversions at the SQLite boundary. Integers saturate and blobs
//! produce structured errors: the domain values we persist are always
//! non-negative, well within i64, and exactly 32 bytes where hashes
//! are concerned, so a violation means a corrupted or foreign row -
//! which should degrade or error, never crash the process.

use crate::merkle::Digest;
use anyhow::anyhow;
use cartesi_machine::types::Hash;

use super::error::Result;

pub(super) fn u64_to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

pub(super) fn i64_to_u64(value: i64) -> u64 {
    value.max(0) as u64
}

pub(super) fn blob_to_hash(blob: Vec<u8>) -> Result<Hash> {
    let len = blob.len();
    blob.try_into()
        .map_err(|_| anyhow!("stored hash has {len} bytes, expected 32").into())
}

pub(super) fn blob_to_digest(blob: Vec<u8>) -> Result<Digest> {
    Digest::from_digest(&blob)
        .map_err(|_| anyhow!("stored digest has {} bytes, expected 32", blob.len()).into())
}
