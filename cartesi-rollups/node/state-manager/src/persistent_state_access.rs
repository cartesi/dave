// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{
    CommitmentLeaf, Epoch, Input, InputId, Settlement, StateManager,
    sql::{consensus_data, migrations, rollup_data},
    state_manager::Result,
};

use rusqlite::{Connection, OptionalExtension};

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

    pub fn new_in_memory() -> std::result::Result<Self, rusqlite_migration::Error> {
        let mut connection = Connection::open_in_memory()?;
        migrations::migrate_to_latest(&mut connection).unwrap();
        Ok(Self { connection })
    }
}

impl StateManager for PersistentStateAccess {
    //
    // Consensus Data
    //
    fn set_genesis(&mut self, block_number: u64) -> Result<()> {
        consensus_data::update_last_processed_block(&self.connection, block_number)
    }

    fn epoch(&mut self, epoch_number: u64) -> Result<Option<Epoch>> {
        consensus_data::epoch(&self.connection, epoch_number)
    }

    fn epoch_count(&mut self) -> Result<u64> {
        consensus_data::epoch_count(&self.connection)
    }

    fn last_sealed_epoch(&mut self) -> Result<Option<Epoch>> {
        consensus_data::last_sealed_epoch(&self.connection)
    }

    fn input(&mut self, id: &InputId) -> Result<Option<Input>> {
        consensus_data::input(&self.connection, id)
    }

    fn inputs(&mut self, epoch_number: u64) -> Result<Vec<Vec<u8>>> {
        consensus_data::inputs(&self.connection, epoch_number)
    }

    fn input_count(&mut self, epoch_number: u64) -> Result<u64> {
        consensus_data::input_count(&self.connection, epoch_number)
    }

    fn last_input(&mut self) -> Result<Option<InputId>> {
        consensus_data::last_input(&self.connection)
    }

    fn latest_processed_block(&mut self) -> Result<u64> {
        consensus_data::last_processed_block(&self.connection)
    }

    fn insert_consensus_data<'a>(
        &mut self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()> {
        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;
        consensus_data::update_last_processed_block(&tx, last_processed_block)?;
        consensus_data::insert_inputs(&tx, inputs)?;
        consensus_data::insert_epochs(&tx, epochs)?;
        tx.commit().map_err(anyhow::Error::from)?;

        Ok(())
    }

    //
    // Rollup Data
    //

    fn add_machine_state_hashes(
        &mut self,
        epoch_number: u64,
        start_state_hash_index: u64,
        leafs: &[CommitmentLeaf],
    ) -> Result<()> {
        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;

        let (leafs, start_state_hash_index) =
            match rollup_data::get_last_state_hash_index(&tx, epoch_number)? {
                Some(last_idx) if start_state_hash_index <= last_idx => {
                    let overlap_len = std::cmp::min(
                        leafs.len(),
                        (last_idx - start_state_hash_index + 1) as usize,
                    );

                    let (dup, new) = (&leafs[..overlap_len], &leafs[overlap_len..]);
                    rollup_data::validate_dup_commitments(
                        &tx,
                        dup,
                        epoch_number,
                        start_state_hash_index,
                    )?;

                    (new, start_state_hash_index + overlap_len as u64)
                }

                Some(last_idx) => {
                    assert_eq!(start_state_hash_index, last_idx + 1);
                    (leafs, start_state_hash_index)
                }

                None => {
                    assert_eq!(start_state_hash_index, 0);
                    (leafs, start_state_hash_index)
                }
            };

        rollup_data::insert_commitments(&tx, epoch_number, start_state_hash_index, leafs)?;

        tx.commit().map_err(anyhow::Error::from)?;
        Ok(())
    }

    fn machine_state_hash(
        &mut self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<Option<CommitmentLeaf>> {
        rollup_data::get_commitment_if_exists(
            &self.connection,
            epoch_number,
            state_hash_index_in_epoch,
        )
    }

    // returns all state hashes and their repetitions in acending order of `state_hash_index_in_epoch`
    fn machine_state_hashes(&mut self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
        rollup_data::get_all_commitments(&self.connection, epoch_number)
    }

    fn add_settlement_info(&mut self, settlement: &Settlement, epoch_number: u64) -> Result<()> {
        // TODO update to an UPSERT?
        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;

        if let Some(ref existing_settlement) = rollup_data::settlement_info(&tx, epoch_number)? {
            assert!(existing_settlement == settlement);
            return Ok(());
        }

        rollup_data::insert_settlement_info(&tx, settlement, epoch_number)?;

        tx.commit().map_err(anyhow::Error::from)?;
        Ok(())
    }

    fn settlement_info(&mut self, epoch_number: u64) -> Result<Option<Settlement>> {
        rollup_data::settlement_info(&self.connection, epoch_number)
    }

    fn add_snapshot(
        &mut self,
        path: &str,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<()> {
        let mut sttm = self.connection.prepare(
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

    fn latest_snapshot(&mut self) -> Result<Option<(String, u64, u64)>> {
        let mut sttm = self
            .connection
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

    fn snapshot(&mut self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Option<String>> {
        let mut sttm = self
            .connection
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
    use crate::Proof;

    use super::*;

    pub fn setup() -> PersistentStateAccess {
        PersistentStateAccess::new_in_memory().unwrap()
    }

    #[test]
    fn test_state_access() -> super::Result<()> {
        let input_0_bytes = b"hello";
        let input_1_bytes = b"world";

        let mut access = setup();

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
        access.add_machine_state_hashes(0, 0, &[commitment_leaf_1.clone()])?;

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

        access.add_machine_state_hashes(0, 1, &[commitment_leaf_2.clone()])?;

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
