// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{
    CommitmentLeaf, Epoch, Input, InputId, Settlement, StateManager,
    sql::{consensus_data, migrations, rollup_data},
    state_manager::Result,
};

use rusqlite::{Connection, OptionalExtension};
use std::sync::Mutex;

#[derive(Debug)]
pub struct PersistentStateAccess {
    connection: Connection,
}

impl PersistentStateAccess {
    pub fn migrate(path: &std::path::Path) -> std::result::Result<(), rusqlite_migration::Error> {
        let mut connection = Connection::open(path)?;
        migrations::migrate_to_latest(&mut connection).unwrap();
        Ok(())
    }

    pub fn new(path: &std::path::Path) -> std::result::Result<Self, rusqlite_migration::Error> {
        let connection = Connection::open(path)?;
        Ok(Self { connection })
    }
}

impl StateManager for PersistentStateAccess {
    //
    // Consensus Data
    //
    fn epoch(&self, epoch_number: u64) -> Result<Option<Epoch>> {
        let conn = self.connection.lock().unwrap();
        consensus_data::epoch(&conn, epoch_number)
    }

    fn epoch_count(&self) -> Result<u64> {
        let conn = self.connection.lock().unwrap();
        consensus_data::epoch_count(&conn)
    }

    fn last_sealed_epoch(&self) -> Result<Option<Epoch>> {
        let conn = self.connection.lock().unwrap();
        consensus_data::last_sealed_epoch(&conn)
    }

    fn input(&self, id: &InputId) -> Result<Option<Input>> {
        let conn = self.connection.lock().unwrap();
        consensus_data::input(&conn, id)
    }

    fn inputs(&self, epoch_number: u64) -> Result<Vec<Vec<u8>>> {
        let conn = self.connection.lock().unwrap();
        consensus_data::inputs(&conn, epoch_number)
    }

    fn input_count(&self, epoch_number: u64) -> Result<u64> {
        let conn = self.connection.lock().unwrap();
        consensus_data::input_count(&conn, epoch_number)
    }

    fn last_input(&self) -> Result<Option<InputId>> {
        let conn = self.connection.lock().unwrap();
        consensus_data::last_input(&conn)
    }

    fn latest_processed_block(&self) -> Result<u64> {
        let conn = self.connection.lock().unwrap();
        consensus_data::last_processed_block(&conn)
    }

    fn insert_consensus_data<'a>(
        &self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()> {
        let mut conn = self.connection.lock().unwrap();
        let tx = conn.transaction().map_err(anyhow::Error::from)?;
        consensus_data::update_last_processed_block(&tx, last_processed_block)?;
        consensus_data::insert_inputs(&tx, inputs)?;
        consensus_data::insert_epochs(&tx, epochs)?;
        tx.commit().map_err(anyhow::Error::from)?;

        Ok(())
    }

    //
    // Rollup Data
    //

    fn add_machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
        leaf: &CommitmentLeaf,
    ) -> Result<()> {
        assert!(leaf.repetitions > 0);

        let mut conn = self.connection.lock().unwrap();
        let tx = conn.transaction().map_err(anyhow::Error::from)?;

        // 1) Check existing, return if correct duplicate
        if let Some(ref existing) =
            rollup_data::get_commitment_if_exists(&tx, epoch_number, state_hash_index_in_epoch)?
        {
            assert!(existing == leaf);
            return Ok(());
        }

        // 2) Validate ordering. TODO: this should probably be an error, and not a panic.
        if let Some(last_idx) = rollup_data::get_last_state_hash_index(&tx, epoch_number)? {
            assert!(state_hash_index_in_epoch == last_idx + 1);
        } else {
            assert!(state_hash_index_in_epoch == 0);
        }

        // 3) Insert new
        rollup_data::insert_commitment(&tx, epoch_number, state_hash_index_in_epoch, leaf)?;

        tx.commit().map_err(anyhow::Error::from)?;
        Ok(())
    }

    fn machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<Option<CommitmentLeaf>> {
        let conn = self.connection.lock().unwrap();
        rollup_data::get_commitment_if_exists(&conn, epoch_number, state_hash_index_in_epoch)
    }

    // returns all state hashes and their repetitions in acending order of `state_hash_index_in_epoch`
    fn machine_state_hashes(&self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
        let conn = self.connection.lock().unwrap();
        rollup_data::get_all_commitments(&conn, epoch_number)
    }

    fn add_settlement_info(&self, settlement: &Settlement, epoch_number: u64) -> Result<()> {
        let mut conn = self.connection.lock().unwrap();

        // TODO update to an UPSERT?
        let tx = conn.transaction().map_err(anyhow::Error::from)?;

        if let Some(ref existing_settlement) = rollup_data::settlement_info(&tx, epoch_number)? {
            assert!(existing_settlement == settlement);
            return Ok(());
        }

        rollup_data::insert_settlement_info(&tx, settlement, epoch_number)?;

        tx.commit().map_err(anyhow::Error::from)?;
        Ok(())
    }

    fn settlement_info(&self, epoch_number: u64) -> Result<Option<Settlement>> {
        let conn = self.connection.lock().unwrap();
        rollup_data::settlement_info(&conn, epoch_number)
    }

    fn add_snapshot(&self, path: &str, epoch_number: u64, input_index_in_epoch: u64) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "INSERT INTO snapshots (epoch_number, input_index_in_epoch, path) VALUES (?1, ?2, ?3)",
        ).map_err(anyhow::Error::from)?;

        let count = sttm
            .execute((epoch_number, input_index_in_epoch, path))
            .map_err(anyhow::Error::from)?;

        assert_eq!(
            count, 1,
            "expected exactly one row to be inserted into snapshots"
        );

        Ok(())
    }

    fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
        let conn = self.connection.lock().unwrap();

        let mut sttm = conn
            .prepare(
                "\
            SELECT epoch_number, input_index_in_epoch, path FROM snapshots
            ORDER BY epoch_number DESC, input_index_in_epoch DESC LIMIT 1
            ",
            )
            .map_err(anyhow::Error::from)?;

        let mut query = sttm.query([]).map_err(anyhow::Error::from)?;

        match query.next().map_err(anyhow::Error::from)? {
            Some(r) => {
                let epoch_number = r.get(0).map_err(anyhow::Error::from)?;
                let input_index_in_epoch = r.get(1).map_err(anyhow::Error::from)?;
                let path = r.get(2).map_err(anyhow::Error::from)?;

                Ok(Some((path, epoch_number, input_index_in_epoch)))
            }
            None => Ok(None),
        }
    }

    fn snapshot(&self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Option<String>> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn
            .prepare(
                "\
            SELECT path FROM snapshots
            WHERE epoch_number = ?1
            AND input_index_in_epoch = ?2
            ",
            )
            .map_err(anyhow::Error::from)?;

        Ok(sttm
            .query_row([epoch_number, input_index_in_epoch], |row| row.get(0))
            .optional()
            .map_err(anyhow::Error::from)?)
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use crate::Proof;

    use super::*;

    pub fn setup() -> PersistentStateAccess {
        let conn = Connection::open_in_memory().unwrap();
        PersistentStateAccess::new(conn).unwrap()
    }

    #[test]
    fn test_state_access() -> super::Result<()> {
        let input_0_bytes = b"hello";
        let input_1_bytes = b"world";

        let access = setup();

        access.insert_consensus_data(
            20,
            [
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 0,
                    },
                    data: input_0_bytes.to_vec(),
                },
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 1,
                    },
                    data: input_1_bytes.to_vec(),
                },
            ]
            .into_iter(),
            [&Epoch {
                epoch_number: 0,
                input_index_boundary: 12,
                root_tournament: String::new(),
                block_created_number: 0,
            }]
            .into_iter(),
        )?;

        assert_eq!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                })?
                .map(|x| x.data),
            Some(input_0_bytes.to_vec()),
            "input 0 bytes should match"
        );
        assert_eq!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 1
                })?
                .map(|x| x.data),
            Some(input_1_bytes.to_vec()),
            "input 1 bytes should match"
        );
        assert!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 2
                })?
                .is_none(),
            "input 2 shouldn't exist"
        );

        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 1,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "duplicate input index should fail"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 3,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "input index should be sequential"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 2,
                        },
                        data: input_1_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_ok(),
            "add sequential input should succeed"
        );

        assert_eq!(
            access.latest_processed_block()?,
            21,
            "latest block should match"
        );

        assert!(
            access.latest_snapshot()?.is_none(),
            "latest snapshot should be empty"
        );

        let (latest_snapshot, epoch_number, input_index_in_epoch) = ("AAA", 0, 0);

        access.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

        assert_eq!(
            access
                .latest_snapshot()?
                .expect("latest snapshot should exists"),
            (
                latest_snapshot.to_string(),
                epoch_number,
                input_index_in_epoch
            ),
            "latest snapshot should match"
        );

        let (latest_snapshot, epoch_number, input_index_in_epoch) = ("BBB", 0, 1);

        access.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

        assert_eq!(
            access
                .latest_snapshot()?
                .expect("latest snapshot should exists"),
            (
                latest_snapshot.to_string(),
                epoch_number,
                input_index_in_epoch
            ),
            "latest snapshot should match"
        );

        let (latest_snapshot, epoch_number, input_index_in_epoch) = ("CCC", 0, 2);

        access.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

        assert_eq!(
            access
                .latest_snapshot()?
                .expect("latest snapshot should exists"),
            (
                latest_snapshot.to_string(),
                epoch_number,
                input_index_in_epoch
            ),
            "latest snapshot should match"
        );

        let (latest_snapshot, epoch_number, input_index_in_epoch) = ("DDD", 3, 1);

        access.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

        assert_eq!(
            access
                .latest_snapshot()?
                .expect("latest snapshot should exists"),
            (
                latest_snapshot.to_string(),
                epoch_number,
                input_index_in_epoch
            ),
            "latest snapshot should match"
        );

        access.add_snapshot("EEE", 0, 4)?;

        assert_eq!(
            access
                .latest_snapshot()?
                .expect("latest snapshot should exists"),
            (
                latest_snapshot.to_string(),
                epoch_number,
                input_index_in_epoch
            ),
            "latest snapshot should match"
        );

        assert!(
            access.machine_state_hash(0, 0)?.is_none(),
            "machine state hash shouldn't exist"
        );
        assert!(
            access.machine_state_hashes(0)?.is_empty(),
            "machine state hashes shouldn't exist"
        );

        let commitment_leaf_1 = CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        };
        let commitment_leaf_2 = CommitmentLeaf {
            hash: [2; 32],
            repetitions: 5,
        };
        // lock problem
        access.add_machine_state_hash(0, 0, &commitment_leaf_1)?;

        assert_eq!(
            access.machine_state_hash(0, 0)?.unwrap(),
            commitment_leaf_1,
            "machine state 1 data should match"
        );
        assert_eq!(
            access.machine_state_hashes(0)?.len(),
            1,
            "machine state 1 count shouldn't exist"
        );

        access.add_machine_state_hash(0, 1, &commitment_leaf_2)?;

        assert_eq!(
            access.machine_state_hash(0, 1)?.unwrap(),
            commitment_leaf_2,
            "machine state 2 data should match"
        );
        assert_eq!(
            access.machine_state_hashes(0)?.len(),
            2,
            "machine state 2 count shouldn't exist"
        );

        assert!(
            access.settlement_info(0)?.is_none(),
            "computation_hash shouldn't exist"
        );

        let settlement_1 = Settlement {
            computation_hash: [3; 32].into(),
            output_merkle: [4; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };

        access.add_settlement_info(&settlement_1, 0)?;

        assert_eq!(
            access.settlement_info(0)?.unwrap(),
            settlement_1,
            "settlement info of epoch 0 should match"
        );

        Ok(())
    }
}
