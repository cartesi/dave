// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{Epoch, Input, InputId, StateManager};

use crate::sql::{consensus_data, error::*, migrations};

use rusqlite::Connection;

pub struct PersistentStateAccess {
    connection: Connection,
}

impl PersistentStateAccess {
    pub fn new(mut connection: Connection) -> std::result::Result<Self, rusqlite_migration::Error> {
        migrations::migrate_to_latest(&mut connection).unwrap();
        Ok(Self { connection })
    }
}

impl StateManager for PersistentStateAccess {
    type Error = PersistentStateAccessError;

    //
    // Consensus Data
    //

    fn epoch_count(&self) -> Result<u64> {
        consensus_data::epoch_count(&self.connection)
    }

    fn input(&self, id: &InputId) -> Result<Option<Input>> {
        consensus_data::input(&self.connection, id)
    }

    fn latest_processed_block(&self) -> Result<u64> {
        consensus_data::last_processed_block(&self.connection)
    }

    fn insert_consensus_data<'a>(
        &self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
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
        input_index_in_epoch: u64,
        _repetitions: u64,
    ) -> Result<()> {
        // add machine state hash
        // 1. successful if the row doesn't exist
        // 2. do nothing if it exists and the state hash is the same
        // 3. return error if it exists with different state hash

        // TODO:
        // If it already exists, it shouldn't be an error (maybe just an assert)
        // Abstractly, for each epoch and each input in epoch, there's an array of state hashes.
        // This means we add an extra column called "index" or "computation_hash" index, which
        // resets after every input.
        // So we could read the last index for that epoch+input, and add a new row with the next
        // index.
        // Furthermore, besides the state hash itself, we have to add the number of
        // repetitions of that state hash.

        let mut sttm = self
            .connection
            .prepare("SELECT * FROM machine_state_hashes WHERE epoch_number = ?1 AND input_index_in_epoch = ?2")?;

        match sttm.query([epoch_number, input_index_in_epoch])?.next()? {
            Some(r) => {
                let read_machine_state_hash: Vec<u8> = r.get(0)?;
                if read_machine_state_hash != machine_state_hash.to_vec() {
                    return Err(PersistentStateAccessError::DuplicateEntry {
                        description: "different machine state hash exists for the same key"
                            .to_owned(),
                    });
                }
            }
            None => {
                // machine state hash doesn't exist
            }
        }

        let mut sttm = self.connection.prepare(
            "INSERT INTO machine_state_hashes (epoch_number, input_index_in_epoch, machine_state_hash) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, machine_state_hash))? != 1 {
            return Err(PersistentStateAccessError::InsertionFailed {
                description: "machine state hash insertion failed".to_owned(),
            });
        }
        Ok(())
    }

    fn add_snapshot(&self, path: &str, epoch_number: u64, input_index_in_epoch: u64) -> Result<()> {
        let mut sttm = self.connection.prepare(
            "INSERT INTO snapshots (epoch_number, input_index_in_epoch, path) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, path))? != 1 {
            return Err(PersistentStateAccessError::InsertionFailed {
                description: "machine snapshot insertion failed".to_owned(),
            });
        }
        Ok(())
    }

    fn machine_state_hash(&self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Vec<u8>> {
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM machine_state_hashes WHERE epoch_number = ?1 AND input_index_in_epoch = ?2")?;
        let mut query = sttm.query([epoch_number, input_index_in_epoch])?;

        match query.next()? {
            Some(r) => {
                let state = r.get(0)?;
                return Ok(state);
            }
            None => {
                return Err(PersistentStateAccessError::DataNotFound {
                    description: "machine state hash doesn't exist".to_owned(),
                });
            }
        }
    }

    fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
        let mut sttm = self.connection.prepare(
            "SELECT epoch_number, input_index_in_epoch, path FROM snapshots \
                ORDER BY \
                    epoch_number DESC, \
                    input_index_in_epoch DESC \
                LIMIT 1",
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
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;

    pub fn setup() -> PersistentStateAccess {
        let conn = Connection::open_in_memory().unwrap();
        let access = PersistentStateAccess::new(conn).unwrap();
        access
    }

    #[test]
    fn test_state_access() -> super::Result<()> {
        let input_0_bytes = b"hello";
        let input_1_bytes = b"world";

        let access = setup();

        // access.add_input(input_0_bytes, 0, 0)?;
        // access.add_input(input_1_bytes, 0, 1)?;

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
                block_sealed: 12,
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
                    [].into_iter().into_iter(),
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
                    [].into_iter().into_iter(),
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
                    [].into_iter().into_iter(),
                )
                .is_ok(),
            "add sequential input should succeed"
        );

        assert_eq!(
            access.latest_processed_block()?,
            21,
            "latest block should match"
        );

        assert_eq!(
            access.latest_snapshot()?.is_none(),
            true,
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

        Ok(())
    }
}
