// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute hero's role: the engine quartet cache, the finalized
//! tournament event log (fold phase 2), and the closed-epoch views
//! it fights tournaments with.
//!
//! The quartet cache's primary key is the coordinate and the hash is
//! the value, so a row, once written, is final - which is what makes
//! a disagreement on insert the nondeterminism tripwire.

use super::Storage;
use super::convert::{blob_to_digest, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use crate::engine::Quartet;

use crate::merkle::Digest;
use alloy::{
    hex::ToHexExt,
    primitives::{Address, U256},
    rpc::types::Log,
};
use rusqlite::{OptionalExtension, params};

impl Storage {
    /// The pinned engine configuration; the migration writes it once.
    pub fn sling_config(&self) -> Result<crate::engine::EngineConfig> {
        crate::engine::config::stored(&self.connection)
            .map_err(StorageError::InnerError)?
            .ok_or_else(|| StorageError::DataNotFound {
                description: "engine config row (the migration pins it)".into(),
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

    /// The dispute's persisted event stream, in chain order (block,
    /// then log index) - the exact order the tournament fold expects.
    /// Only finalized events live here (fold phase 2); the tail past
    /// the watermark is refetched live each tick.
    pub fn tournament_events(&mut self, root_tournament: Address) -> Result<Vec<Log>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    "SELECT raw_log FROM tournament_events
                     WHERE root_tournament = ?1
                     ORDER BY block_number ASC, log_index ASC",
                )
                .map_err(anyhow::Error::from)?;
            let rows = stmt
                .query_map([root_tournament.encode_hex()], |row| {
                    row.get::<_, Vec<u8>>(0)
                })
                .map_err(anyhow::Error::from)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)?
                .into_iter()
                .map(|blob| Ok(serde_json::from_slice(&blob).map_err(anyhow::Error::from)?))
                .collect()
        })
    }

    /// The highest finalized block whose events are fully persisted
    /// for this dispute; None before the first tick persists.
    pub fn tournament_events_watermark(&mut self, root_tournament: Address) -> Result<Option<u64>> {
        let block = self
            .connection
            .query_row(
                "SELECT finalized_block FROM tournament_events_watermark
                 WHERE root_tournament = ?1",
                [root_tournament.encode_hex()],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(anyhow::Error::from)?;
        Ok(block.map(i64_to_u64))
    }

    /// One tick's finalized harvest: advance the watermark to
    /// `finalized_block` and append the events at or below it, in one
    /// transaction. The watermark moves first so the schema trigger
    /// (events must not outrun it) sees the new bound; it advances
    /// even on an empty harvest, keeping the live tail refetch
    /// bounded. Replayed ticks are absorbed: identical rows are
    /// ignored, and the monotone trigger rejects a rewind.
    pub fn append_tournament_events(
        &mut self,
        root_tournament: Address,
        finalized_block: u64,
        events: &[&Log],
    ) -> Result<()> {
        let rows = events
            .iter()
            .map(|log| {
                let block = log
                    .block_number
                    .ok_or_else(|| anyhow::anyhow!("chain log without a block number"))?;
                let index = log
                    .log_index
                    .ok_or_else(|| anyhow::anyhow!("chain log without a log index"))?;
                anyhow::ensure!(
                    block <= finalized_block,
                    "unfinalized event offered for persistence (block {block} > finalized {finalized_block})"
                );
                let blob = serde_json::to_vec(log).map_err(anyhow::Error::from)?;
                Ok((block, index, blob))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        self.write(|tx| {
            tx.execute(
                "INSERT INTO tournament_events_watermark VALUES (?1, ?2)
                 ON CONFLICT (root_tournament)
                 DO UPDATE SET finalized_block = MAX(finalized_block, excluded.finalized_block)",
                params![root_tournament.encode_hex(), u64_to_i64(finalized_block)],
            )
            .map_err(anyhow::Error::from)?;

            for (block, index, blob) in &rows {
                tx.execute(
                    "INSERT INTO tournament_events VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT DO NOTHING",
                    params![
                        root_tournament.encode_hex(),
                        u64_to_i64(*block),
                        u64_to_i64(*index),
                        blob,
                    ],
                )
                .map_err(anyhow::Error::from)?;
            }
            Ok(())
        })
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
