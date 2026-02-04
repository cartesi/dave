// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::PathBuf;

use crate::{CommitmentLeaf, InputId, Proof, Settlement, state_manager::Result};

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

    // final_state blob -> [u8;32]
    let fs_blob: Vec<u8> = row.get(1)?;
    let final_state: Hash = fs_blob.try_into().expect("final_state must be 32 bytes");

    // output_merkle blob -> [u8;32]
    let om_blob: Vec<u8> = row.get(2)?;
    let output_merkle: Hash = om_blob.try_into().expect("output_merkle must be 32 bytes");

    // output_proof blob -> Proof
    let proof_blob: Vec<u8> = row.get(3)?;
    let output_proof = Proof::from_flattened(proof_blob);

    Ok(Settlement {
        computation_hash,
        final_state,
        output_merkle,
        output_proof,
    })
}

pub fn get_all_commitments(conn: &Connection, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT machine_state_hash, repetitions
            FROM machine_state_hashes
            WHERE epoch_number = ?1
            ORDER BY
                input_number ASC,
                hash_index   ASC
            "#,
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

pub fn insert_state_hashes_for_input(
    conn: &Connection,
    epoch_number: u64,
    input_number: u64,
    leafs: &[CommitmentLeaf],
) -> Result<()> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            INSERT INTO machine_state_hashes
            (epoch_number, input_number, hash_index, repetitions, machine_state_hash)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    for (i, leaf) in leafs.iter().enumerate() {
        let count = stmt
            .execute(params![
                epoch_number,
                input_number,
                i,
                leaf.repetitions,
                leaf.hash.as_ref(),
            ])
            .map_err(anyhow::Error::from)?;

        assert_eq!(
            count, 1,
            "expected exactly one row to be inserted into machine_state_hashes"
        );
    }

    Ok(())
}

pub fn settlement_info(conn: &Connection, epoch_number: u64) -> Result<Option<Settlement>> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT computation_hash, final_state, output_merkle, output_proof
            FROM settlement_info
            WHERE epoch_number = ?1
            "#,
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
    let mut stmt = conn
        .prepare_cached(
            r#"
            INSERT INTO settlement_info
            (epoch_number, computation_hash, final_state, output_merkle, output_proof)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let count = stmt
        .execute(params![
            epoch_number,
            settlement.computation_hash.data(),
            settlement.final_state,
            &settlement.output_merkle,
            &settlement.output_proof.flatten(),
        ])
        .map_err(anyhow::Error::from)?;

    assert_eq!(count, 1, "expected exactly one row inserted");
    Ok(())
}

pub fn insert_template_machine(
    conn: &Connection,
    state_hash: &cartesi_machine::types::Hash,
) -> Result<()> {
    let mut sttm = conn
        .prepare_cached(
            r#"
            INSERT OR IGNORE INTO template_machine (id, state_hash)
            VALUES(1, ?1)
            "#,
        )
        .map_err(anyhow::Error::from)?;
    sttm.execute(rusqlite::params![state_hash])
        .map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn insert_snapshot(
    conn: &Connection,
    epoch_number: u64,
    input_number: u64,
    state_hash: &cartesi_machine::types::Hash,
    dest_dir: &std::path::Path,
) -> Result<()> {
    let mut sttm = conn
        .prepare_cached(
            r#"
            INSERT INTO machine_state_snapshots(state_hash, file_path)
            VALUES(?1, ?2)
            ON CONFLICT(state_hash) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;
    sttm.execute(rusqlite::params![state_hash, dest_dir.to_string_lossy()])
        .map_err(anyhow::Error::from)?;

    let mut sttm = conn
        .prepare_cached(
            r#"
            INSERT INTO epoch_snapshot_info(epoch_number, input_number, state_hash)
            VALUES(?1, ?2, ?3)
            ON CONFLICT(epoch_number, input_number) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;
    sttm.execute(rusqlite::params![epoch_number, input_number, state_hash])
        .map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn gc_old_epochs(conn: &Connection, max_epoch: u64) -> Result<()> {
    conn.execute(
        r#"
        DELETE FROM epoch_snapshot_info
        WHERE epoch_number <= ?1
        "#,
        [max_epoch],
    )
    .map_err(anyhow::Error::from)?;

    conn.execute_batch(
        r#"
        DELETE FROM machine_state_snapshots
        WHERE state_hash NOT IN (
            SELECT state_hash FROM epoch_snapshot_info
            UNION
            SELECT state_hash FROM template_machine
        );
        "#,
    )
    .map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn gc_previous_advances(conn: &Connection, epoch: u64, input_anchor: u64) -> Result<()> {
    conn.execute(
        r#"
        DELETE FROM epoch_snapshot_info
        WHERE epoch_number = ?1 AND (input_number != ?2 AND input_number != 0)
        "#,
        [epoch, input_anchor],
    )
    .map_err(anyhow::Error::from)?;

    conn.execute_batch(
        r#"
        DELETE FROM machine_state_snapshots
        WHERE state_hash NOT IN (
            SELECT state_hash FROM epoch_snapshot_info
            UNION
            SELECT state_hash FROM template_machine
        );
        "#,
    )
    .map_err(anyhow::Error::from)?;

    Ok(())
}

pub fn next_input_to_be_processed(conn: &Connection) -> Result<InputId> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT epoch_number, input_number
            FROM epoch_snapshot_info
            ORDER BY
                epoch_number DESC,
                input_number DESC
            LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let (epoch_number, input_index_in_epoch): (u64, u64) = stmt
        .query_row([], |row| Ok((row.get(0)?, row.get(1)?)))
        .expect("there should at least be a single latest processed");

    Ok(InputId {
        epoch_number,
        input_index_in_epoch,
    })
}

pub fn latest_snapshot_path(conn: &Connection) -> Result<(PathBuf, u64, u64)> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT s.file_path, e.epoch_number, e.input_number
            FROM epoch_snapshot_info AS e
            JOIN machine_state_snapshots AS s
            ON s.state_hash = e.state_hash
            ORDER BY
                e.epoch_number DESC,
                e.input_number DESC
            LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let (path, epoch, input): (String, u64, u64) = stmt
        .query_row([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .expect("there should at least be a single machine");

    Ok((path.into(), epoch, input))
}

pub fn snapshot_path_for_epoch(
    conn: &Connection,
    epoch_number: u64,
    input_number: u64,
) -> Result<Option<PathBuf>> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT s.file_path
            FROM epoch_snapshot_info AS e
            JOIN machine_state_snapshots AS s
            ON s.state_hash = e.state_hash
            WHERE e.epoch_number = ?1 AND e.input_number= ?2
            "#,
        )
        .map_err(anyhow::Error::from)?;

    Ok(stmt
        .query_row([epoch_number, input_number], |row| row.get::<_, String>(0))
        .optional()
        .map(|opt| opt.map(PathBuf::from))
        .map_err(anyhow::Error::from)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::{CommitmentLeaf, Proof, Settlement, sql::test_helper::*};
    use rusqlite::Connection;
    use tempfile::TempDir;

    /// Convenience: count rows in a table.
    fn count_rows(conn: &Connection, table: &str) -> u32 {
        conn.query_row::<u32, _, _>(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .expect("count should succeed")
    }

    #[test]
    fn get_all_commitments_single() {
        let (_handle, conn) = setup_db();
        let leaf = CommitmentLeaf {
            hash: [7; 32],
            repetitions: 5,
        };
        insert_state_hashes_for_input(&conn, 42, 0, &[leaf.clone()]).unwrap();

        let fetched = get_all_commitments(&conn, 42).unwrap();
        assert_eq!(fetched, vec![leaf]);
    }

    #[test]
    fn get_all_commitments_multiple_inputs_ordering() {
        let (_handle, conn) = setup_db();
        // Two different input indices; ordering must be input_number ASC, hash_index ASC
        let l0 = CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        };
        let l1 = CommitmentLeaf {
            hash: [2; 32],
            repetitions: 1,
        };
        // input 0
        insert_state_hashes_for_input(&conn, 7, 0, &[l0.clone()]).unwrap();
        // input 1
        insert_state_hashes_for_input(&conn, 7, 1, &[l1.clone()]).unwrap();

        let all = get_all_commitments(&conn, 7).unwrap();
        assert_eq!(all, vec![l0, l1]);
    }

    #[test]
    fn get_all_commitments_empty_epoch_returns_empty_vec() {
        let (_handle, conn) = setup_db();
        let res = get_all_commitments(&conn, 999).unwrap();
        assert!(res.is_empty());
    }

    #[test]
    fn insert_state_hashes_empty_slice_is_noop() {
        let (_handle, conn) = setup_db();

        let before = count_rows(&conn, "machine_state_hashes");
        insert_state_hashes_for_input(&conn, 1, 0, &[]).unwrap();
        let after = count_rows(&conn, "machine_state_hashes");

        assert_eq!(before, after);
    }

    #[test]
    fn insert_state_hashes_duplicate_primary_key_fails() {
        let (_handle, conn) = setup_db();

        let leaves = [CommitmentLeaf {
            hash: [9; 32],
            repetitions: 1,
        }];

        // first insert succeeds
        insert_state_hashes_for_input(&conn, 2, 0, &leaves).unwrap();
        // second insert should fail due to UNIQUE(epoch,input,hash_index)
        let err = insert_state_hashes_for_input(&conn, 2, 0, &leaves).expect_err("should fail");
        assert!(matches!(err, crate::StateAccessError::InnerError(_)));
    }

    #[test]
    fn settlement_info_none() {
        let (_handle, conn) = setup_db();
        assert!(settlement_info(&conn, 1).unwrap().is_none());
    }

    #[test]
    fn insert_and_get_settlement_info() {
        let (_handle, conn) = setup_db();
        let settlement = Settlement {
            computation_hash: [0xAA; 32].into(),
            final_state: [0xBB; 32],
            output_merkle: [0xCC; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        insert_settlement_info(&conn, &settlement, 42).unwrap();
        let fetched = settlement_info(&conn, 42).unwrap().unwrap();
        assert_eq!(fetched, settlement);
    }

    #[test]
    fn insert_settlement_info_duplicate_returns_error() {
        let (_handle, conn) = setup_db();
        let settlement = Settlement {
            computation_hash: [0x11; 32].into(),
            final_state: [0x22; 32],
            output_merkle: [0x33; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        insert_settlement_info(&conn, &settlement, 55).unwrap();
        let err = insert_settlement_info(&conn, &settlement, 55).expect_err("duplicate must fail");
        assert!(matches!(err, crate::StateAccessError::InnerError(_)));
    }

    /// Makes a unique temporary directory path for snapshots.
    fn tmp_dir() -> TempDir {
        TempDir::new().expect("create tempdir")
    }

    #[test]
    fn insert_snapshot_and_latest_path() {
        let (_handle, conn) = setup_db();
        let dir = tmp_dir();

        insert_snapshot(&conn, 42, 2, &[1u8; 32], dir.path()).unwrap();
        let (p, e, i) = latest_snapshot_path(&conn).unwrap();
        let id = next_input_to_be_processed(&conn).unwrap();

        assert_eq!(p, dir.path());
        assert_eq!(e, 42);
        assert_eq!(i, 2);

        assert_eq!(e, id.epoch_number);
        assert_eq!(i, id.input_index_in_epoch);
    }

    #[test]
    fn snapshot_path_for_epoch_happy_and_none() {
        let (_handle, conn) = setup_db();
        let dir1 = tmp_dir();
        let dir2 = tmp_dir();

        insert_snapshot(&conn, 10, 0, &[1u8; 32], dir1.path()).unwrap();
        insert_snapshot(&conn, 11, 1, &[2u8; 32], dir2.path()).unwrap();

        // happy path
        let p = snapshot_path_for_epoch(&conn, 10, 0).unwrap().unwrap();
        assert_eq!(p, dir1.path());

        // unknown epoch/input returns None
        assert!(snapshot_path_for_epoch(&conn, 99, 99).unwrap().is_none());
    }

    #[test]
    fn gc_previous_advances_keeps_anchor_input() {
        let (_handle, conn) = setup_db();
        let epoch = 5u64;
        let hashes: [[u8; 32]; 4] = [[1; 32], [2; 32], [3; 32], [4; 32]];
        let dirs: Vec<TempDir> = (0..4).map(|_| tmp_dir()).collect();

        for (input, (hash, dir)) in hashes.into_iter().zip(dirs.iter()).enumerate() {
            insert_snapshot(&conn, epoch, input as u64, &hash, dir.path()).unwrap();
        }

        // sanity
        assert_eq!(
            conn.query_row::<u32, _, _>(
                "SELECT COUNT(*) FROM epoch_snapshot_info WHERE epoch_number = ?",
                [epoch],
                |r| r.get(0),
            )
            .unwrap(),
            4 // 4 we inserted
        );

        gc_previous_advances(&conn, epoch, 2).unwrap();

        // Only template (input 0) + anchor (input 2)
        let remaining: u32 = conn
            .query_row(
                "SELECT COUNT(*) FROM epoch_snapshot_info WHERE epoch_number = ?",
                [epoch],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 2);
    }

    #[test]
    fn insert_template_machine_is_idempotent() {
        let (_handle, conn) = setup_db();
        let h = [0xFFu8; 32];
        insert_template_machine(&conn, &h).unwrap();
        insert_template_machine(&conn, &h).unwrap();
        assert_eq!(count_rows(&conn, "template_machine"), 1);
    }
}
