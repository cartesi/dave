// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::sql::{consensus_data, error::*, migrations};
use crate::{Epoch, Input, InputId, Proof, StateManager};

use rusqlite::{Connection, OptionalExtension};
use std::sync::Mutex;

#[derive(Debug)]
pub struct PersistentStateAccess {
    connection: Mutex<Connection>,
}

impl PersistentStateAccess {
    pub fn new(mut connection: Connection) -> std::result::Result<Self, rusqlite_migration::Error> {
        migrations::migrate_to_latest(&mut connection).unwrap();
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }
}

impl StateManager for PersistentStateAccess {
    type Error = PersistentStateAccessError;

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
        let conn = self.connection.lock().unwrap();
        let tx = conn.unchecked_transaction()?;
        consensus_data::update_last_processed_block(&tx, last_processed_block)?;
        consensus_data::insert_inputs(&tx, inputs)?;
        consensus_data::insert_epochs(&tx, epochs)?;
        tx.commit()?;

        Ok(())
    }

    //
    // Rollup Data
    //

    fn add_machine_state_hash(
        &self,
        machine_state_hash: &[u8],
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
        repetitions: u64,
    ) -> Result<()> {
        // add machine state hash
        // 1. successful if the row doesn't exist
        // 2. do nothing if it exists and the state hash and repetitions is the same
        // 3. panicr if it exists with different state hash or repetitions

        // If it already exists, it shouldn't be an error (maybe just an assert)
        // Abstractly, for each epoch, there's an array of state hashes, the "state_hash_index"
        // column is an index local to an epoch.
        // So we could read the last index for that epoch, and add a new row with the next
        // index.

        assert!(repetitions > 0);

        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "\
            SELECT * FROM machine_state_hashes
            WHERE epoch_number = ?1
            AND state_hash_index_in_epoch = ?2
            ",
        )?;

        match sttm
            .query([epoch_number, state_hash_index_in_epoch])?
            .next()?
        {
            Some(r) => {
                // previous row with same key found, all values should match
                let read_machine_state_hash: Vec<u8> = r.get("machine_state_hash")?;
                let read_repetitions: u64 = r.get("repetitions")?;
                assert!(read_machine_state_hash == machine_state_hash.to_vec());
                assert!(read_repetitions == repetitions);

                return Ok(());
            }
            None => {
                // machine state hash doesn't exist
            }
        }

        let mut sttm = conn.prepare(
            "\
            SELECT state_hash_index_in_epoch FROM machine_state_hashes
            WHERE epoch_number = ?1
            ORDER BY state_hash_index_in_epoch DESC LIMIT 1
            ",
        )?;

        let current_machine_state_index: Option<u64> = sttm
            .query_row([epoch_number], |row| row.get(0))
            .optional()?;

        match current_machine_state_index {
            Some(index) => {
                // `state_hash_index_in_epoch` should increment from previous index
                assert!(state_hash_index_in_epoch == index + 1);
            }
            None => {
                // `state_hash_index_in_epoch` should start increment from 0 with every epoch
                assert!(state_hash_index_in_epoch == 0);
            }
        }

        let mut sttm = conn.prepare(
            "\
            INSERT INTO machine_state_hashes
            (epoch_number, state_hash_index_in_epoch, repetitions, machine_state_hash)
            VALUES (?1, ?2, ?3, ?4)
            ",
        )?;

        if sttm.execute((
            epoch_number,
            state_hash_index_in_epoch,
            repetitions,
            machine_state_hash,
        ))? != 1
        {
            return Err(PersistentStateAccessError::InsertionFailed {
                description: "machine state hash insertion failed".to_owned(),
            });
        }
        Ok(())
    }

    fn settlement_info(&self, epoch_number: u64) -> Result<Option<(Vec<u8>, Vec<u8>, Proof)>> {
        let conn = self.connection.lock().unwrap();
        let mut stmt = conn.prepare(
            "\
            SELECT computation_hash, output_merkle, output_proof FROM settlement_info
            WHERE epoch_number = ?1
            ",
        )?;

        Ok(stmt
            .query_row([epoch_number], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get::<_, Vec<u8>>(2)?.into()))
            })
            .optional()?)
    }

    fn add_settlement_info(
        &self,
        computation_hash: &[u8],
        output_merkle: &[u8],
        output_proof: &Proof,
        epoch_number: u64,
    ) -> Result<()> {
        if let Some((c, o_m, o_p)) = self.settlement_info(epoch_number)? {
            // a row with same key found, all values should match
            assert!(c == computation_hash.to_vec());
            assert!(o_m == output_merkle.to_vec());
            assert!(o_p == *output_proof);

            return Ok(());
        }

        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "INSERT INTO settlement_info (epoch_number, computation_hash, output_merkle, output_proof) VALUES (?1, ?2, ?3, ?4)",
        )?;

        if sttm.execute((
            epoch_number,
            computation_hash,
            output_merkle,
            output_proof.flatten(),
        ))? != 1
        {
            return Err(PersistentStateAccessError::InsertionFailed {
                description: "machine computation_hash insertion failed".to_owned(),
            });
        }
        Ok(())
    }

    fn add_snapshot(&self, path: &str, epoch_number: u64, input_index_in_epoch: u64) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "INSERT INTO snapshots (epoch_number, input_index_in_epoch, path) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, path))? != 1 {
            return Err(PersistentStateAccessError::InsertionFailed {
                description: "machine snapshot insertion failed".to_owned(),
            });
        }
        Ok(())
    }

    fn machine_state_hash(
        &self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<(Vec<u8>, u64)> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "\
            SELECT * FROM machine_state_hashes
            WHERE epoch_number = ?1
            AND state_hash_index_in_epoch = ?2
            ",
        )?;
        let mut query = sttm.query([epoch_number, state_hash_index_in_epoch])?;

        match query.next()? {
            Some(r) => {
                let state = r.get("machine_state_hash")?;
                let repetitions = r.get("repetitions")?;
                Ok((state, repetitions))
            }
            None => Err(PersistentStateAccessError::DataNotFound {
                description: "machine state hash doesn't exist".to_owned(),
            }),
        }
    }

    // returns all state hashes and their repetitions in acending order of `state_hash_index_in_epoch`
    fn machine_state_hashes(&self, epoch_number: u64) -> Result<Vec<(Vec<u8>, u64)>> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "\
            SELECT * FROM machine_state_hashes
            WHERE epoch_number = ?1
            ORDER BY state_hash_index_in_epoch ASC
            ",
        )?;
        let query = sttm.query_map([epoch_number], |r| {
            Ok((r.get("machine_state_hash")?, r.get("repetitions")?))
        })?;

        let mut res = vec![];
        for row in query {
            res.push(row?);
        }

        Ok(res)
    }

    fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "\
            SELECT epoch_number, input_index_in_epoch, path FROM snapshots
            ORDER BY epoch_number DESC, input_index_in_epoch DESC LIMIT 1
            ",
        )?;
        let mut query = sttm.query([])?;

        match query.next()? {
            Some(r) => {
                let epoch_number = r.get(0)?;
                let input_index_in_epoch = r.get(1)?;
                let path = r.get(2)?;

                Ok(Some((path, epoch_number, input_index_in_epoch)))
            }
            None => Ok(None),
        }
    }

    fn snapshot(&self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Option<String>> {
        let conn = self.connection.lock().unwrap();
        let mut sttm = conn.prepare(
            "\
            SELECT path FROM snapshots
            WHERE epoch_number = ?1
            AND input_index_in_epoch = ?2
            ",
        )?;

        Ok(sttm
            .query_row([epoch_number, input_index_in_epoch], |row| row.get(0))
            .optional()?)
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

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
            access.machine_state_hash(0, 0).is_err(),
            "machine state hash shouldn't exist"
        );
        assert!(
            access.machine_state_hashes(0).is_ok_and(|x| x.is_empty()),
            "machine state hashes shouldn't exist"
        );

        let machine_state_hash_1 = vec![1, 2, 3, 4, 5];
        let machine_state_hash_2 = vec![2, 2, 3, 4, 5];
        // lock problem
        access.add_machine_state_hash(&machine_state_hash_1, 0, 0, 1)?;

        assert_eq!(
            access.machine_state_hash(0, 0)?,
            (machine_state_hash_1, 1),
            "machine state 1 data should match"
        );
        assert_eq!(
            access.machine_state_hashes(0)?.len(),
            1,
            "machine state 1 count shouldn't exist"
        );

        access.add_machine_state_hash(&machine_state_hash_2, 0, 1, 5)?;

        assert_eq!(
            access.machine_state_hash(0, 1)?,
            (machine_state_hash_2, 5),
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

        let computation_hash_1 = vec![1, 2, 3, 4, 5];
        let output_merkle_1 = vec![1, 2, 3, 4, 4];
        let output_proof_1: Proof = vec![
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
            25, 26, 27, 28, 29, 30, 31, 32,
        ]
        .into();
        access.add_settlement_info(&computation_hash_1, &output_merkle_1, &output_proof_1, 0)?;

        assert_eq!(
            access.settlement_info(0)?,
            Some((computation_hash_1, output_merkle_1, output_proof_1)),
            "settlement info of epoch 0 should match"
        );

        Ok(())
    }
}
