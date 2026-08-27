// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The role-free read surface: point reads any worker may issue.
//! Writes are role-locked to their files (`ingest`, `advance`,
//! `dispute`); reads are shared vocabulary.

use super::convert::{blob_to_hash, i64_to_u64, u64_to_i64};
use super::error::{Result, StorageError};
use super::{Epoch, Input, InputId, LeafProof, MachineValidityProof, Proof, Settlement, Storage};

use alloy::hex::FromHex;
use alloy::primitives::Address;
use rusqlite::{OptionalExtension, Row, Transaction, params, types::ValueRef};

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

    /// Every sealed epoch in order: the bond recovery planner's
    /// candidate roots, each written from the trusted consensus
    /// stream.
    pub fn sealed_epochs(&mut self) -> Result<Vec<Epoch>> {
        self.read(|tx| {
            let mut stmt = tx
                .prepare_cached(
                    r#"
                    SELECT epoch_number, input_index_boundary, root_tournament,
                           block_created_number
                    FROM epochs
                    ORDER BY epoch_number ASC
                    "#,
                )
                .map_err(anyhow::Error::from)?;

            let rows = stmt
                .query_map([], row_to_epoch)
                .map_err(anyhow::Error::from)?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(anyhow::Error::from)?
                .into_iter()
                .collect::<Result<Vec<_>>>()
        })
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
            SELECT computation_hash, final_state,
                   iflags_y_data_block, iflags_y_siblings,
                   htif_tohost_data_block, htif_tohost_siblings,
                   tx_buffer_data_block, tx_buffer_siblings
            FROM settlement_info
            WHERE epoch_number = ?1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    Ok(stmt
        .query_row(params![u64_to_i64(epoch_number)], |row| {
            row_to_settlement(row, epoch_number)
        })
        .optional()
        .map_err(anyhow::Error::from)?)
}

fn row_to_settlement(row: &Row<'_>, epoch_number: u64) -> rusqlite::Result<Settlement> {
    let settlement = Settlement {
        computation_hash: settlement_value(
            epoch_number,
            "computation_hash",
            super::convert::blob_to_digest(settlement_blob(
                row,
                0,
                epoch_number,
                "computation_hash",
            )?),
        ),
        final_state: settlement_value(
            epoch_number,
            "final_state",
            blob_to_hash(settlement_blob(row, 1, epoch_number, "final_state")?),
        ),
        machine_validity_proof: MachineValidityProof {
            iflags_y_proof: LeafProof {
                data_block: settlement_value(
                    epoch_number,
                    "iflags_y_data_block",
                    blob_to_hash(settlement_blob(
                        row,
                        2,
                        epoch_number,
                        "iflags_y_data_block",
                    )?),
                ),
                siblings: settlement_value(
                    epoch_number,
                    "iflags_y_siblings",
                    Proof::from_flattened(settlement_blob(
                        row,
                        3,
                        epoch_number,
                        "iflags_y_siblings",
                    )?),
                ),
            },
            htif_tohost_proof: LeafProof {
                data_block: settlement_value(
                    epoch_number,
                    "htif_tohost_data_block",
                    blob_to_hash(settlement_blob(
                        row,
                        4,
                        epoch_number,
                        "htif_tohost_data_block",
                    )?),
                ),
                siblings: settlement_value(
                    epoch_number,
                    "htif_tohost_siblings",
                    Proof::from_flattened(settlement_blob(
                        row,
                        5,
                        epoch_number,
                        "htif_tohost_siblings",
                    )?),
                ),
            },
            tx_buffer_proof: LeafProof {
                data_block: settlement_value(
                    epoch_number,
                    "tx_buffer_data_block",
                    blob_to_hash(settlement_blob(
                        row,
                        6,
                        epoch_number,
                        "tx_buffer_data_block",
                    )?),
                ),
                siblings: settlement_value(
                    epoch_number,
                    "tx_buffer_siblings",
                    Proof::from_flattened(settlement_blob(
                        row,
                        7,
                        epoch_number,
                        "tx_buffer_siblings",
                    )?),
                ),
            },
        },
    };
    super::rollups_machine::validate_machine_validity_proof(
        settlement.final_state,
        &settlement.machine_validity_proof,
    )
    .unwrap_or_else(|error| {
        panic!(
            "settlement for epoch {epoch_number} has an invalid machine validity proof: \
             {error:#} (corruption or incompatible state dir)"
        )
    });
    Ok(settlement)
}

fn settlement_blob(
    row: &Row<'_>,
    index: usize,
    epoch_number: u64,
    field: &str,
) -> rusqlite::Result<Vec<u8>> {
    let value = row.get_ref(index)?;
    match value {
        ValueRef::Blob(blob) => Ok(blob.to_vec()),
        _ => panic!(
            "settlement for epoch {epoch_number} has invalid {field}: expected BLOB, found {:?} \
             (corruption or incompatible state dir)",
            value.data_type()
        ),
    }
}

fn settlement_value<T>(epoch_number: u64, field: &str, value: Result<T>) -> T {
    value.unwrap_or_else(|error| {
        panic!(
            "settlement for epoch {epoch_number} has invalid {field}: {error} \
             (corruption or incompatible state dir)"
        )
    })
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

#[cfg(test)]
pub(super) fn test_settlement() -> Settlement {
    use cartesi_machine::{
        cartesi_machine_sys::{
            CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_SHIFT, CM_HTIF_DEV_YIELD, CM_HTIF_REASON_SHIFT,
            CM_HTIF_YIELD_CMD_MANUAL, CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, CM_REG_HTIF_TOHOST,
            CM_REG_IFLAGS_Y,
        },
        config::runtime::RuntimeConfig,
        constants::ar::TX_START,
        machine::Machine,
    };

    let mut config = Machine::default_config().unwrap();
    config.ram.length = 4096;
    let mut machine = Machine::create(&config, &RuntimeConfig::quiet_console()).unwrap();
    let htif_tohost = (u64::from(CM_HTIF_DEV_YIELD) << CM_HTIF_DEV_SHIFT)
        | (u64::from(CM_HTIF_YIELD_CMD_MANUAL) << CM_HTIF_CMD_SHIFT)
        | (u64::from(CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED) << CM_HTIF_REASON_SHIFT);
    machine.write_reg(CM_REG_IFLAGS_Y, 1).unwrap();
    machine.write_reg(CM_REG_HTIF_TOHOST, htif_tohost).unwrap();
    machine.write_memory(TX_START, &[0x33; 32]).unwrap();
    let (final_state, machine_validity_proof) =
        super::rollups_machine::machine_validity_proof_for(&mut machine).unwrap();

    Settlement {
        computation_hash: [0xAA; 32].into(),
        final_state,
        machine_validity_proof,
    }
}

#[cfg(test)]
pub(super) fn setup_settlement_storage() -> (tempfile::TempDir, Storage) {
    let dir = tempfile::tempdir().unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("db.sqlite3")).unwrap();
    super::sql::schema::initialize(&conn).unwrap();
    drop(conn);
    let storage = Storage::new(dir.path()).unwrap();
    (dir, storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    const RAW_SETTLEMENT_INSERT: &str = r#"
        INSERT INTO settlement_info
        (epoch_number, computation_hash, final_state,
         iflags_y_data_block, iflags_y_siblings,
         htif_tohost_data_block, htif_tohost_siblings,
         tx_buffer_data_block, tx_buffer_siblings)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    "#;

    #[test]
    fn settlement_row_maps_columns_to_domain() {
        let (_handle, mut storage) = setup_settlement_storage();
        let settlement = test_settlement();
        let proof = &settlement.machine_validity_proof;
        storage
            .connection
            .execute(
                RAW_SETTLEMENT_INSERT,
                params![
                    42,
                    settlement.computation_hash.data(),
                    settlement.final_state,
                    proof.iflags_y_proof.data_block,
                    proof.iflags_y_proof.siblings.flatten(),
                    proof.htif_tohost_proof.data_block,
                    proof.htif_tohost_proof.siblings.flatten(),
                    proof.tx_buffer_proof.data_block,
                    proof.tx_buffer_proof.siblings.flatten(),
                ],
            )
            .unwrap();

        assert_eq!(storage.settlement_info(42).unwrap(), Some(settlement));
    }

    #[test]
    #[should_panic(expected = "invalid htif_tohost_siblings")]
    fn malformed_settlement_proof_is_not_retryable() {
        let (_handle, mut storage) = setup_settlement_storage();
        storage
            .connection
            .pragma_update(None, "ignore_check_constraints", "ON")
            .unwrap();
        storage
            .connection
            .execute(
                RAW_SETTLEMENT_INSERT,
                params![
                    42,
                    vec![0u8; 32],
                    vec![0u8; 32],
                    vec![0u8; 32],
                    vec![0u8; 1888],
                    vec![0u8; 32],
                    vec![0u8; 1856],
                    vec![0u8; 32],
                    vec![0u8; 1888],
                ],
            )
            .unwrap();

        let _ = storage.settlement_info(42);
    }

    #[test]
    #[should_panic(expected = "invalid machine validity proof")]
    fn same_length_settlement_corruption_is_not_retryable() {
        let (_handle, mut storage) = setup_settlement_storage();
        let settlement = test_settlement();
        let proof = &settlement.machine_validity_proof;
        let mut corrupted_siblings = proof.htif_tohost_proof.siblings.flatten();
        corrupted_siblings[0] ^= 1;
        storage
            .connection
            .execute(
                RAW_SETTLEMENT_INSERT,
                params![
                    42,
                    settlement.computation_hash.data(),
                    settlement.final_state,
                    proof.iflags_y_proof.data_block,
                    proof.iflags_y_proof.siblings.flatten(),
                    proof.htif_tohost_proof.data_block,
                    corrupted_siblings,
                    proof.tx_buffer_proof.data_block,
                    proof.tx_buffer_proof.siblings.flatten(),
                ],
            )
            .unwrap();

        let _ = storage.settlement_info(42);
    }

    #[test]
    #[should_panic(expected = "expected BLOB, found Text")]
    fn wrong_settlement_sqlite_type_is_not_retryable() {
        let (_handle, mut storage) = setup_settlement_storage();
        let settlement = test_settlement();
        let proof = &settlement.machine_validity_proof;
        storage
            .connection
            .pragma_update(None, "ignore_check_constraints", "ON")
            .unwrap();
        storage
            .connection
            .execute(
                RAW_SETTLEMENT_INSERT,
                params![
                    42,
                    "x".repeat(32),
                    settlement.final_state,
                    proof.iflags_y_proof.data_block,
                    proof.iflags_y_proof.siblings.flatten(),
                    proof.htif_tohost_proof.data_block,
                    proof.htif_tohost_proof.siblings.flatten(),
                    proof.tx_buffer_proof.data_block,
                    proof.tx_buffer_proof.siblings.flatten(),
                ],
            )
            .unwrap();

        let _ = storage.settlement_info(42);
    }
}
