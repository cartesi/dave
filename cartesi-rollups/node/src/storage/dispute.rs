// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute hero's role: the engine quartet cache and the
//! closed-epoch views it fights tournaments with.
//!
//! The quartet cache's primary key is the coordinate and the hash is
//! the value, so a row, once written, is final - which is what makes
//! a disagreement on insert the nondeterminism tripwire.

use super::Storage;
use super::convert::{blob_to_digest, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use crate::engine::Quartet;

use crate::merkle::Digest;
use alloy::primitives::U256;
use rusqlite::{OptionalExtension, params};

impl Storage {
    /// The pinned engine configuration; initialization writes it once.
    pub fn sling_config(&self) -> Result<crate::engine::EngineConfig> {
        crate::engine::config::stored(&self.connection)
            .map_err(StorageError::InnerError)?
            .ok_or_else(|| StorageError::DataNotFound {
                description: "engine config row (initialization pins it)".into(),
            })
    }

    pub fn quartet_node(&self, quartet: &Quartet) -> Result<Option<Digest>> {
        let hash = self
            .connection
            .query_row(
                "SELECT hash FROM sling_nodes
                 WHERE epoch = ?1 AND log2_stride = ?2 AND height = ?3 AND shift = ?4",
                params![
                    u64_to_i64(quartet.epoch),
                    u64_to_i64(quartet.log2_stride),
                    u64_to_i64(quartet.height),
                    shift_blob(&quartet.shift),
                ],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()
            .map_err(anyhow::Error::from)?;
        hash.map(blob_to_digest).transpose()
    }

    /// Inserts computed quartet nodes. An existing row must agree;
    /// determinism makes concurrent duplicates benign, so a
    /// disagreement is the loudest possible signal (nondeterminism or
    /// version drift). The schema trigger enforces the same tripwire
    /// below this check.
    pub fn insert_quartet_nodes(&mut self, rows: &[(Quartet, Digest)]) -> Result<()> {
        self.write(|tx| insert_quartet_nodes_in(tx, rows))
    }

    /// How many window-root rows sit in the recorded prefix (shift
    /// below `below`). Bounded deliberately: the coordinate also
    /// carries machine-bought rows beyond the prefix - a dispute
    /// descent through a padding window's root stores its fanout
    /// there, a final and correct value - so only the prefix speaks
    /// for the open regime. Zero on a store the runner has not
    /// processed (or an inputless epoch); the facade cross-checks
    /// nonzero counts against the epoch's input count.
    pub fn window_root_count(
        &mut self,
        epoch: u64,
        log2_stride: u64,
        height: u64,
        below: u64,
    ) -> Result<u64> {
        let count: i64 = self
            .connection
            .query_row(
                "SELECT COUNT(*) FROM sling_nodes
                 WHERE epoch = ?1 AND log2_stride = ?2 AND height = ?3 AND shift < ?4",
                params![
                    u64_to_i64(epoch),
                    u64_to_i64(log2_stride),
                    u64_to_i64(height),
                    shift_blob(&U256::from(below)),
                ],
                |row| row.get(0),
            )
            .map_err(anyhow::Error::from)?;
        Ok(i64_to_u64(count))
    }

    /// The recorded prefix of window roots, in window order, as one
    /// range scan bounded to shifts below `expected` (rows beyond the
    /// prefix are machine-bought padding roots, not the runner's).
    /// Strict within the prefix: the advance commit prepays every
    /// recorded window's row, so a hole or a count mismatch is
    /// corruption or version drift, never something to heal around.
    pub fn window_root_range(
        &mut self,
        epoch: u64,
        log2_stride: u64,
        height: u64,
        expected: u64,
    ) -> Result<Vec<Digest>> {
        let rows: Vec<(Vec<u8>, Vec<u8>)> = self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    "SELECT shift, hash FROM sling_nodes
                     WHERE epoch = ?1 AND log2_stride = ?2 AND height = ?3 AND shift < ?4
                     ORDER BY shift ASC",
                )
                .map_err(anyhow::Error::from)?;
            let rows = stmt
                .query_map(
                    params![
                        u64_to_i64(epoch),
                        u64_to_i64(log2_stride),
                        u64_to_i64(height),
                        shift_blob(&U256::from(expected)),
                    ],
                    |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?)),
                )
                .map_err(anyhow::Error::from)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|e| anyhow::Error::from(e).into())
        })?;

        // Invariant violations panic (see insert_quartet_nodes_in):
        // the tick loops retry Err forever, which would turn a
        // corrupt store into a silent livelock while the dispute
        // clock runs out.
        assert_eq!(
            rows.len() as u64,
            expected,
            "epoch {epoch} has {} window-root rows, expected {expected}: \
             corruption or version drift",
            rows.len()
        );
        rows.into_iter()
            .enumerate()
            .map(|(window, (shift, hash))| {
                assert_eq!(
                    shift,
                    shift_blob(&U256::from(window)),
                    "window-root rows of epoch {epoch} have a hole at window \
                     {window}: corruption or version drift"
                );
                blob_to_digest(hash)
            })
            .collect()
    }
}

/// The transaction body of [`Storage::insert_quartet_nodes`], also
/// batched into the advance commit (the open regime's window-root
/// rows land atomically with their input's hash runs).
pub(super) fn insert_quartet_nodes_in(
    tx: &rusqlite::Transaction,
    rows: &[(Quartet, Digest)],
) -> Result<()> {
    for (quartet, hash) in rows {
        let inserted = tx
            .execute(
                "INSERT INTO sling_nodes VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT DO NOTHING",
                params![
                    u64_to_i64(quartet.epoch),
                    u64_to_i64(quartet.log2_stride),
                    u64_to_i64(quartet.height),
                    shift_blob(&quartet.shift),
                    hash.slice(),
                ],
            )
            .map_err(anyhow::Error::from)?;
        if inserted == 0 {
            let stored: Vec<u8> = tx
                .query_row(
                    "SELECT hash FROM sling_nodes
                     WHERE epoch = ?1 AND log2_stride = ?2 AND height = ?3 AND shift = ?4",
                    params![
                        u64_to_i64(quartet.epoch),
                        u64_to_i64(quartet.log2_stride),
                        u64_to_i64(quartet.height),
                        shift_blob(&quartet.shift),
                    ],
                    |row| row.get(0),
                )
                .map_err(anyhow::Error::from)?;
            // Invariant violations panic and take the node down (the
            // worker join propagates); an Err here would be swallowed
            // by the tick loops' warn-and-retry, silencing the
            // loudest signal the node has.
            assert_eq!(
                blob_to_digest(stored)?,
                *hash,
                "node cache collision at {quartet:?}: nondeterminism or version drift"
            );
        }
    }
    Ok(())
}

fn shift_blob(shift: &U256) -> [u8; 32] {
    shift.to_be_bytes::<32>()
}
