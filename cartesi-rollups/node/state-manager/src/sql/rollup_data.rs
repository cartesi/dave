// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::PathBuf;

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
        .prepare_cached(
            r#"
            SELECT machine_state_hash, repetitions
            FROM machine_state_hashes
            WHERE epoch_number = ?1
            ORDER BY state_hash_index_in_epoch ASC
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

pub fn get_commitment_if_exists(
    conn: &Connection,
    epoch_number: u64,
    state_hash_index_in_epoch: u64,
) -> Result<Option<CommitmentLeaf>> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT machine_state_hash, repetitions
            FROM machine_state_hashes
            WHERE epoch_number = ?1 AND state_hash_index_in_epoch = ?2
            "#,
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
        .prepare_cached(
            r#"
            SELECT state_hash_index_in_epoch
            FROM machine_state_hashes
            WHERE epoch_number = ?1
            ORDER BY state_hash_index_in_epoch DESC LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;
    let idx = stmt
        .query_row(params![epoch_number], |r| r.get(0))
        .optional()
        .map_err(anyhow::Error::from)?;
    Ok(idx)
}

pub fn validate_dup_commitments(
    conn: &Connection,
    dups: &[CommitmentLeaf],
    epoch_number: u64,
    start_state_hash_index: u64,
) -> Result<()> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT machine_state_hash, repetitions
            FROM machine_state_hashes
            WHERE epoch_number = ?1
            AND state_hash_index_in_epoch BETWEEN ?2 AND ?3
            ORDER BY state_hash_index_in_epoch
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let rows: Vec<CommitmentLeaf> = stmt
        .query_map(
            rusqlite::params![
                epoch_number,
                start_state_hash_index,
                start_state_hash_index + dups.len() as u64 - 1
            ],
            convert_row_to_commitment_leaf,
        )
        .map_err(anyhow::Error::from)?
        .collect::<rusqlite::Result<_>>()
        .map_err(anyhow::Error::from)?;

    assert_eq!(rows, dups);

    Ok(())
}

pub fn insert_commitments(
    conn: &Connection,
    epoch_number: u64,
    start_index: u64,
    leafs: &[CommitmentLeaf],
) -> Result<()> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            INSERT INTO machine_state_hashes
            (epoch_number, state_hash_index_in_epoch, repetitions, machine_state_hash)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    for (i, leaf) in leafs.iter().enumerate() {
        let idx = start_index + i as u64;
        let count = stmt
            .execute(params![
                epoch_number,
                idx,
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
            SELECT computation_hash, output_merkle, output_proof
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
            (epoch_number, computation_hash, output_merkle, output_proof)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let count = stmt
        .execute(params![
            epoch_number,
            settlement.computation_hash.data(),
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
            INSERT INTO epoch_snapshot_info(epoch_number, state_hash)
            VALUES(?1, ?2)
            ON CONFLICT(epoch_number) DO NOTHING
            "#,
        )
        .map_err(anyhow::Error::from)?;
    sttm.execute(rusqlite::params![epoch_number, state_hash])
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

pub fn latest_snapshot_path(conn: &Connection) -> Result<(PathBuf, u64)> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT s.file_path, e.epoch_number
            FROM epoch_snapshot_info AS e
            JOIN machine_state_snapshots AS s
            ON s.state_hash = e.state_hash
            ORDER BY e.epoch_number DESC
            LIMIT 1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    let (path, epoch): (String, u64) = stmt
        .query_row([], |row| Ok((row.get(0)?, row.get(1)?)))
        .expect("there should at least be a single machine");

    Ok((path.into(), epoch))
}

pub fn snapshot_path_for_epoch(conn: &Connection, epoch_number: u64) -> Result<Option<PathBuf>> {
    let mut stmt = conn
        .prepare_cached(
            r#"
            SELECT s.file_path
            FROM epoch_snapshot_info AS e
            JOIN machine_state_snapshots AS s
            ON s.state_hash = e.state_hash
            WHERE e.epoch_number = ?1
            "#,
        )
        .map_err(anyhow::Error::from)?;

    Ok(stmt
        .query_row([epoch_number], |row| row.get::<_, String>(0))
        .optional()
        .map(|opt| opt.map(PathBuf::from))
        .map_err(anyhow::Error::from)?)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::{Proof, sql::test_helper::*};

    #[test]
    fn test_get_commitment_if_exists_none() {
        let (_handle, conn) = setup_db();
        let res = get_commitment_if_exists(&conn, 1, 0).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_insert_and_get_commitment() {
        let (_handle, conn) = setup_db();
        let leaf = CommitmentLeaf {
            hash: [
                0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            ],
            repetitions: 3,
        };
        insert_commitments(&conn, 42, 7, &[leaf.clone()]).unwrap();
        let res = get_commitment_if_exists(&conn, 42, 7).unwrap();
        assert_eq!(res.unwrap(), leaf);
    }

    #[test]
    fn test_get_last_state_hash_index_none() {
        let (_handle, conn) = setup_db();
        let res = get_last_state_hash_index(&conn, 99).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_get_last_state_hash_index_some() {
        let (_handle, conn) = setup_db();
        let leaf1 = CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        };
        let leaf2 = CommitmentLeaf {
            hash: [2; 32],
            repetitions: 1,
        };
        let leaf3 = CommitmentLeaf {
            hash: [3; 32],
            repetitions: 1,
        };
        insert_commitments(&conn, 5, 0, &[leaf1.clone(), leaf2.clone(), leaf3.clone()]).unwrap();
        let res = get_last_state_hash_index(&conn, 5).unwrap();
        assert_eq!(res, Some(2));
    }

    #[test]
    fn test_get_all_commitments_single() {
        let (_handle, conn) = setup_db();
        let leaf = CommitmentLeaf {
            hash: [7; 32],
            repetitions: 5,
        };
        insert_commitments(&conn, 42, 0, &[leaf.clone()]).unwrap();
        let fetched = get_all_commitments(&conn, 42).unwrap();
        assert_eq!(fetched, vec![leaf]);
    }

    #[test]
    fn test_get_all_commitments() {
        let (_handle, conn) = setup_db();
        let leaf1 = CommitmentLeaf {
            hash: [3; 32],
            repetitions: 10,
        };
        let leaf2 = CommitmentLeaf {
            hash: [4; 32],
            repetitions: 20,
        };
        insert_commitments(&conn, 7, 0, &[leaf1.clone(), leaf2.clone()]).unwrap();
        let all = get_all_commitments(&conn, 7).unwrap();
        assert_eq!(all, vec![leaf1, leaf2]);
    }

    #[test]
    fn test_settlement_info_none() {
        let (_handle, conn) = setup_db();
        let res = settlement_info(&conn, 1).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn test_insert_and_get_settlement_info() {
        let (_handle, conn) = setup_db();
        let settlement = Settlement {
            computation_hash: [0xAA; 32].into(),
            output_merkle: [0xBB; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        insert_settlement_info(&conn, &settlement, 42).unwrap();
        let fetched = settlement_info(&conn, 42).unwrap().unwrap();
        assert_eq!(fetched, settlement);
    }

    #[test]
    fn test_validate_dup_commitments_ok() {
        let (_handle, conn) = setup_db();

        let dups = vec![
            CommitmentLeaf {
                hash: [1; 32],
                repetitions: 2,
            },
            CommitmentLeaf {
                hash: [2; 32],
                repetitions: 1,
            },
            CommitmentLeaf {
                hash: [3; 32],
                repetitions: 4,
            },
        ];
        insert_commitments(&conn, 11, 5, &dups).unwrap();

        // Should not panic / return Err
        validate_dup_commitments(&conn, &dups, 11, 5).unwrap();
    }

    #[test]
    #[should_panic(expected = "assertion `left == right` failed")]
    fn test_validate_dup_commitments_mismatch_panics() {
        let (_handle, conn) = setup_db();

        let stored = vec![
            CommitmentLeaf {
                hash: [9; 32],
                repetitions: 1,
            },
            CommitmentLeaf {
                hash: [8; 32],
                repetitions: 1,
            },
        ];
        insert_commitments(&conn, 22, 0, &stored).unwrap();

        // Alter one repetition so the helper must panic
        let wrong = vec![
            CommitmentLeaf {
                hash: [9; 32],
                repetitions: 2,
            }, // <- mismatch
            CommitmentLeaf {
                hash: [8; 32],
                repetitions: 1,
            },
        ];

        // Panics due to assert_eq! inside helper
        validate_dup_commitments(&conn, &wrong, 22, 0).unwrap();
    }

    #[test]
    #[should_panic(expected = "UNIQUE constraint failed")]
    fn test_insert_duplicate_state_hash_index_panics() {
        let (_handle, conn) = setup_db();

        let leaf = CommitmentLeaf {
            hash: [5; 32],
            repetitions: 1,
        };
        insert_commitments(&conn, 33, 0, &[leaf.clone()]).unwrap();

        // Attempt to insert another leaf at the same index ⇒ sqlite UNIQUE violation
        insert_commitments(&conn, 33, 0, &[leaf]).unwrap();
    }

    #[test]
    fn test_insert_commitments_sparse_indices() {
        let (_handle, conn) = setup_db();

        let batch1 = vec![
            CommitmentLeaf {
                hash: [1; 32],
                repetitions: 1,
            },
            CommitmentLeaf {
                hash: [2; 32],
                repetitions: 1,
            },
        ];
        insert_commitments(&conn, 44, 0, &batch1).unwrap();

        let batch2 = vec![CommitmentLeaf {
            hash: [3; 32],
            repetitions: 1,
        }];
        // Insert starting at index 5 leaving gaps (allowed by schema)
        insert_commitments(&conn, 44, 5, &batch2).unwrap();

        // Should reflect the sparse insertion
        let all = get_all_commitments(&conn, 44).unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(get_commitment_if_exists(&conn, 44, 3).unwrap(), None);
        assert_eq!(
            get_commitment_if_exists(&conn, 44, 5).unwrap(),
            Some(batch2[0].clone())
        );
    }

    #[test]
    #[should_panic(expected = "UNIQUE constraint failed")]
    fn test_insert_settlement_info_duplicate_panics() {
        let (_handle, conn) = setup_db();
        let settlement = Settlement {
            computation_hash: [0x11; 32].into(),
            output_merkle: [0x22; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };
        insert_settlement_info(&conn, &settlement, 55).unwrap();
        // Second insert for same epoch violates PRIMARY KEY on epoch_number
        insert_settlement_info(&conn, &settlement, 55).unwrap();
    }

    // helper: makes a fake path like "./snap_xx"
    fn tmp_dir(idx: u8) -> PathBuf {
        std::env::temp_dir().join(format!("snap_{idx}"))
    }

    #[test]
    fn test_insert_snapshot_and_latest_path() {
        let (_handle, conn) = setup_db();
        fs::create_dir_all(tmp_dir(1)).unwrap();

        insert_snapshot(&conn, 42, &[1u8; 32], &tmp_dir(1)).unwrap();
        let (p, e) = latest_snapshot_path(&conn).unwrap();
        assert_eq!(p, tmp_dir(1));
        assert_eq!(e, 42);
    }

    #[test]
    fn test_insert_snapshot_duplicate_state_hash() {
        let (_handle, conn) = setup_db();
        fs::create_dir_all(tmp_dir(2)).unwrap();
        fs::create_dir_all(tmp_dir(3)).unwrap();

        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM machine_state_snapshots", [], |r| r
                .get(0))
                .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM epoch_snapshot_info", [], |r| r
                .get(0))
                .unwrap(),
            1
        );

        let h = &[2u8; 32];
        insert_snapshot(&conn, 1, h, &tmp_dir(2)).unwrap();
        insert_snapshot(&conn, 2, h, &tmp_dir(2)).unwrap();

        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM machine_state_snapshots", [], |r| r
                .get(0))
                .unwrap(),
            2
        );
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM epoch_snapshot_info", [], |r| r
                .get(0))
                .unwrap(),
            3
        );
    }

    #[test]
    fn test_gc_old_epochs_removes_unreachable_snapshots() {
        let (_handle, conn) = setup_db();

        // template hash
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM machine_state_snapshots", [], |r| r
                .get(0))
                .unwrap(),
            1
        );

        // epoch 0
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM epoch_snapshot_info", [], |r| r
                .get(0))
                .unwrap(),
            1
        );

        fs::create_dir_all(tmp_dir(5)).unwrap();
        fs::create_dir_all(tmp_dir(6)).unwrap();
        fs::create_dir_all(tmp_dir(7)).unwrap();
        insert_snapshot(&conn, 1, &[5u8; 32], &tmp_dir(5)).unwrap();
        insert_snapshot(&conn, 2, &[6u8; 32], &tmp_dir(6)).unwrap();
        insert_snapshot(&conn, 3, &[7u8; 32], &tmp_dir(7)).unwrap();

        // epoch 0, 1, 2 and 3
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM epoch_snapshot_info", [], |r| r
                .get(0))
                .unwrap(),
            4
        );

        // keep > epoch 2 (and epoch 0)
        gc_old_epochs(&conn, 2).unwrap();

        // epoch 0, 1 and 2 rows gone
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM epoch_snapshot_info", [], |r| r
                .get(0))
                .unwrap(),
            1
        );

        // unreachable parent rows gone too: only epoch 3 and template hash.
        assert_eq!(
            conn.query_row::<u32, _, _>("SELECT COUNT(*) FROM machine_state_snapshots", [], |r| r
                .get(0))
                .unwrap(),
            2
        );
    }

    #[test]
    fn test_latest_snapshot_path_after_gc() {
        let (_handle, conn) = setup_db();
        fs::create_dir_all(tmp_dir(8)).unwrap();
        fs::create_dir_all(tmp_dir(9)).unwrap();

        insert_snapshot(&conn, 10, &[8u8; 32], &tmp_dir(8)).unwrap();
        insert_snapshot(&conn, 11, &[9u8; 32], &tmp_dir(9)).unwrap();
        gc_old_epochs(&conn, 10).unwrap();

        let (p, e) = latest_snapshot_path(&conn).unwrap();
        assert_eq!(p, tmp_dir(9));
        assert_eq!(e, 11);
    }

    #[test]
    #[should_panic(expected = "assertion `left == right` failed")]
    fn test_validate_dup_commitments_wrong_hash_panics() {
        let (_handle, conn) = setup_db();
        let stored = vec![CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        }];
        insert_commitments(&conn, 99, 0, &stored).unwrap();

        let wrong = vec![CommitmentLeaf {
            hash: [2; 32],
            repetitions: 1,
        }];

        validate_dup_commitments(&conn, &wrong, 99, 0).unwrap();
    }
}
