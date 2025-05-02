// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{CommitmentLeaf, Proof, Settlement, state_manager::Result};

use cartesi_machine::types::Hash;

use rusqlite::{Connection, OptionalExtension, params};

fn convert_row_to_commitment_leaf(r: &rusqlite::Row) -> rusqlite::Result<CommitmentLeaf> {
    let hash: Hash = {
        let vec: Vec<u8> = r.get(0)?;
        vec.try_into()
            .expect("machine_state_hash should have 32 bytes")
    };

    let repetitions: u64 = r.get(1)?;

    Ok(CommitmentLeaf { hash, repetitions })
}

fn convert_row_to_settlement(row: &rusqlite::Row) -> rusqlite::Result<Settlement> {
    // computation_hash blob -> [u8;32] -> Digest
    let ch_blob: Vec<u8> = row.get(0)?;
    let ch_arr: [u8; 32] = ch_blob
        .try_into()
        .expect("computation_hash must be 32 bytes");
    let computation_hash = ch_arr.into();

    // output_merkle blob -> [u8;32]
    let om_blob: Vec<u8> = row.get(1)?;
    let output_merkle: Hash = om_blob.try_into().expect("output_merkle must be 32 bytes");

    // output_proof blob -> Proof
    let proof_blob: Vec<u8> = row.get(2)?;
    let output_proof = Proof::from_flattened(proof_blob);

    Ok(Settlement {
        computation_hash,
        output_merkle,
        output_proof,
    })
}

pub fn get_all_commitments(conn: &Connection, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
    let mut stmt = conn
        .prepare(
            "SELECT machine_state_hash, repetitions \
             FROM machine_state_hashes \
             WHERE epoch_number = ?1
             ORDER BY state_hash_index_in_epoch ASC",
        )
        .map_err(anyhow::Error::from)?;

    let rows = stmt
        .query_map(params![epoch_number], convert_row_to_commitment_leaf)
        .map_err(anyhow::Error::from)?;

    let res = rows
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(anyhow::Error::from)?;
    Ok(res)
}

pub fn get_commitment_if_exists(
    conn: &Connection,
    epoch_number: u64,
    state_hash_index_in_epoch: u64,
) -> Result<Option<CommitmentLeaf>> {
    let mut stmt = conn
        .prepare(
            "SELECT machine_state_hash, repetitions \
             FROM machine_state_hashes \
             WHERE epoch_number = ?1 AND state_hash_index_in_epoch = ?2",
        )
        .map_err(anyhow::Error::from)?;
    let row = stmt
        .query_row(
            params![epoch_number, state_hash_index_in_epoch],
            convert_row_to_commitment_leaf,
        )
        .optional()
        .map_err(anyhow::Error::from)?;
    Ok(row)
}

pub fn get_last_state_hash_index(conn: &Connection, epoch_number: u64) -> Result<Option<u64>> {
    let mut stmt = conn
        .prepare(
            "SELECT state_hash_index_in_epoch \
             FROM machine_state_hashes \
             WHERE epoch_number = ?1 \
             ORDER BY state_hash_index_in_epoch DESC LIMIT 1",
        )
        .map_err(anyhow::Error::from)?;
    let idx = stmt
        .query_row(params![epoch_number], |r| r.get(0))
        .optional()
        .map_err(anyhow::Error::from)?;
    Ok(idx)
}

pub fn insert_commitment(
    conn: &Connection,
    epoch_number: u64,
    state_hash_index_in_epoch: u64,
    leaf: &CommitmentLeaf,
) -> Result<()> {
    let count = conn
        .execute(
            "INSERT INTO machine_state_hashes \
             (epoch_number, state_hash_index_in_epoch, repetitions, machine_state_hash) \
             VALUES (?1, ?2, ?3, ?4)",
            params![
                epoch_number,
                state_hash_index_in_epoch,
                leaf.repetitions,
                leaf.hash.as_ref(),
            ],
        )
        .map_err(anyhow::Error::from)?;

    assert_eq!(
        count, 1,
        "expected exactly one row to be inserted into machine_state_hashes"
    );

    Ok(())
}

pub fn settlement_info(conn: &Connection, epoch_number: u64) -> Result<Option<Settlement>> {
    let mut stmt = conn
        .prepare(
            "SELECT computation_hash, output_merkle, output_proof
            FROM settlement_info
            WHERE epoch_number = ?1",
        )
        .map_err(anyhow::Error::from)?;

    let settlement = stmt
        .query_row(params![epoch_number], convert_row_to_settlement)
        .optional()
        .map_err(anyhow::Error::from)?;

    Ok(settlement)
}

pub fn insert_settlement_info(
    conn: &Connection,
    settlement: &Settlement,
    epoch_number: u64,
) -> Result<()> {
    let count = conn
        .execute(
            "INSERT INTO settlement_info \
            (epoch_number, computation_hash, output_merkle, output_proof) \
            VALUES (?1, ?2, ?3, ?4)",
            params![
                epoch_number,
                settlement.computation_hash.data(),
                &settlement.output_merkle,
                &settlement.output_proof.flatten(),
            ],
        )
        .map_err(anyhow::Error::from)?;

    assert_eq!(count, 1, "expected exactly one row inserted");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Proof, sql::test_helper::*};

    #[test]
    fn test_get_commitment_if_exists_none() {
        let conn = setup_db();
        let res = get_commitment_if_exists(&conn, 1, 0).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_insert_and_get_commitment() {
        let conn = setup_db();
        let leaf = CommitmentLeaf {
            hash: [
                0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            ],
            repetitions: 3,
        };
        insert_commitment(&conn, 42, 7, &leaf).unwrap();
        let res = get_commitment_if_exists(&conn, 42, 7).unwrap();
        assert_eq!(res.unwrap(), leaf);
    }

    #[test]
    fn test_get_last_state_hash_index_none() {
        let conn = setup_db();
        let res = get_last_state_hash_index(&conn, 99).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_get_last_state_hash_index_some() {
        let conn = setup_db();
        let leaf1 = CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        };
        let leaf2 = CommitmentLeaf {
            hash: [2; 32],
            repetitions: 1,
        };
        insert_commitment(&conn, 5, 0, &leaf1).unwrap();
        insert_commitment(&conn, 5, 2, &leaf2).unwrap();
        let res = get_last_state_hash_index(&conn, 5).unwrap();
        assert_eq!(res, Some(2));
    }

    #[test]
    fn test_get_all_commitments_single() {
        let conn = setup_db();
        let leaf = CommitmentLeaf {
            hash: [7; 32],
            repetitions: 5,
        };
        insert_commitment(&conn, 42, 0, &leaf).unwrap();
        let fetched = get_all_commitments(&conn, 42).unwrap();
        assert_eq!(fetched, vec![leaf]);
    }

    #[test]
    fn test_get_all_commitments() {
        let conn = setup_db();
        let leaf1 = CommitmentLeaf {
            hash: [3; 32],
            repetitions: 10,
        };
        let leaf2 = CommitmentLeaf {
            hash: [4; 32],
            repetitions: 20,
        };
        insert_commitment(&conn, 7, 0, &leaf1).unwrap();
        insert_commitment(&conn, 7, 1, &leaf2).unwrap();
        let all = get_all_commitments(&conn, 7).unwrap();
        assert_eq!(all, vec![leaf1, leaf2]);
    }

    #[test]
    fn test_settlement_info_none() {
        let conn = setup_db();
        let res = settlement_info(&conn, 1).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_insert_and_get_settlement_info() {
        let conn = setup_db();
        let settlement = Settlement {
            computation_hash: [0xAA; 32].into(),
            output_merkle: [0xBB; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        insert_settlement_info(&conn, &settlement, 42).unwrap();
        let fetched = settlement_info(&conn, 42).unwrap().unwrap();
        assert_eq!(fetched, settlement);
    }
}
