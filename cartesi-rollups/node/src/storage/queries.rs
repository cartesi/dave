// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The role-free read surface: point reads any worker may issue.
//! Writes are role-locked to their files (`ingest`, `advance`,
//! `dispute`); reads are shared vocabulary.

use super::convert::{blob_to_hash, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use super::{Epoch, Input, InputId, Proof, Settlement, Storage};

use alloy::hex::FromHex;
use alloy::primitives::Address;
use rusqlite::{OptionalExtension, Transaction, params};

impl Storage {
    pub fn latest_processed_block(&mut self) -> Result<u64> {
        self.read(|tx| {
            let block: i64 = tx
                .query_row("SELECT block FROM latest_processed WHERE id = 1", [], |r| {
                    r.get(0)
                })
                .map_err(anyhow::Error::from)?;
            Ok(i64_to_u64(block))
        })
    }

    pub fn epoch_count(&mut self) -> Result<u64> {
        self.read(epoch_count_in)
    }

    pub fn last_sealed_epoch(&mut self) -> Result<Option<Epoch>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT epoch_number, input_index_boundary, root_tournament,
                           block_created_number
                    FROM epochs
                    ORDER BY epoch_number DESC
                    LIMIT 1
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            stmt.query_row([], row_to_epoch)
                .optional()
                .map_err(anyhow::Error::from)?
                .transpose()
        })
    }

    pub fn input(&mut self, id: &InputId) -> Result<Option<Input>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT input FROM inputs
                    WHERE epoch_number = ?1 AND input_index_in_epoch = ?2
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            let data = stmt
                .query_row(
                    params![
                        u64_to_i64(id.epoch_number),
                        u64_to_i64(id.input_index_in_epoch)
                    ],
                    |row| row.get(0),
                )
                .optional()
                .map_err(anyhow::Error::from)?;

            Ok(data.map(|data| Input {
                id: id.clone(),
                data,
            }))
        })
    }

    pub fn inputs(&mut self, epoch_number: u64) -> Result<Vec<Vec<u8>>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT input FROM inputs
                    WHERE epoch_number = ?1
                    ORDER BY input_index_in_epoch ASC
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            let rows = stmt
                .query_map([u64_to_i64(epoch_number)], |r| r.get(0))
                .map_err(anyhow::Error::from)?;

            Ok(rows
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)?)
        })
    }

    pub fn last_input(&mut self) -> Result<Option<InputId>> {
        self.read(last_input_in)
    }

    /// How many inputs an epoch holds: the fed-window count the
    /// geometry needs, without materializing any payload.
    pub fn input_count(&mut self, epoch_number: u64) -> Result<u64> {
        self.read(|tx| {
            let count: i64 = tx
                .query_row(
                    "SELECT COUNT(*) FROM inputs WHERE epoch_number = ?1",
                    params![u64_to_i64(epoch_number)],
                    |row| row.get(0),
                )
                .map_err(anyhow::Error::from)?;
            Ok(i64_to_u64(count))
        })
    }

    /// The resume point: the coordinate of the newest snapshot
    /// boundary, whose input is the next to process.
    pub fn next_input_id(&mut self) -> Result<InputId> {
        self.read(|tx| {
            let (_, epoch_number, input_index_in_epoch, _) =
                super::snapshots::latest_boundary_in(tx)?;
            Ok(InputId {
                epoch_number,
                input_index_in_epoch,
            })
        })
    }

    pub fn settlement_info(&mut self, epoch_number: u64) -> Result<Option<Settlement>> {
        self.read(|tx| settlement_info_in(tx, epoch_number))
    }
}

//
// Transaction-level readers shared across roles
//

pub(super) fn epoch_count_in(tx: &Transaction) -> Result<u64> {
    let max: Option<i64> = tx
        .query_row("SELECT MAX(epoch_number) FROM epochs", [], |row| row.get(0))
        .map_err(anyhow::Error::from)?;
    Ok(max.map(|x| i64_to_u64(x) + 1).unwrap_or(0))
}

pub(super) fn last_input_in(tx: &Transaction) -> Result<Option<InputId>> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            SELECT epoch_number, input_index_in_epoch FROM inputs
            ORDER BY epoch_number DESC, input_index_in_epoch DESC
            LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    Ok(stmt
        .query_row([], |row| {
            Ok(InputId {
                epoch_number: i64_to_u64(row.get(0)?),
                input_index_in_epoch: i64_to_u64(row.get(1)?),
            })
        })
        .optional()
        .map_err(anyhow::Error::from)?)
}

pub(super) fn settlement_info_in(
    tx: &Transaction,
    epoch_number: u64,
) -> Result<Option<Settlement>> {
    let mut stmt = tx
        .prepare_cached(
            r#"
            SELECT computation_hash, outputs_merkle_root, outputs_merkle_root_proof, final_state
            FROM settlement_info
            WHERE epoch_number = ?1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let row = stmt
        .query_row(params![u64_to_i64(epoch_number)], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, Vec<u8>>(3)?,
            ))
        })
        .optional()
        .map_err(anyhow::Error::from)?;

    row.map(
        |(computation_hash, outputs_merkle_root, outputs_merkle_root_proof, final_state)| {
            Ok(Settlement {
                computation_hash: super::convert::blob_to_digest(computation_hash)?,
                final_state: blob_to_hash(final_state)?,
                outputs_merkle_root: blob_to_hash(outputs_merkle_root)?,
                outputs_merkle_root_proof: Proof::from_flattened(outputs_merkle_root_proof)?,
            })
        },
    )
    .transpose()
}

fn row_to_epoch(row: &rusqlite::Row) -> rusqlite::Result<Result<Epoch>> {
    let tournament_str: String = row.get(2)?;
    let epoch_number: i64 = row.get(0)?;
    let input_index_boundary: i64 = row.get(1)?;
    let block_created_number: i64 = row.get(3)?;

    Ok(Address::from_hex(&tournament_str)
        .map_err(|e| {
            StorageError::InnerError(anyhow::anyhow!(
                "stored tournament address `{tournament_str}` is invalid: {e}"
            ))
        })
        .map(|root_tournament| Epoch {
            epoch_number: i64_to_u64(epoch_number),
            input_index_boundary: i64_to_u64(input_index_boundary),
            root_tournament,
            block_created_number: i64_to_u64(block_created_number),
        }))
}
