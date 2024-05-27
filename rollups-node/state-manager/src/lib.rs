// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::Result;
use rusqlite::Connection;

pub struct StateManager {
    connection: Connection,
}

impl StateManager {
    pub fn connect(database_uri: &str) -> Result<Self> {
        let connection = Connection::open(database_uri)?;
        // constants table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS constants (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL
            );",
            (),
        )?;
        // epochs table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS epochs (
                epoch_number INTEGER NOT NULL PRIMARY KEY,
                block_sealed INTEGER NOT NULL,
                settled BOOLEAN NOT NULL
            );",
            (),
        )?;
        // inputs table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS inputs (
                epoch_number INTEGER NOT NULL,
                input_index_in_epoch INTEGER NOT NULL,
                input BLOB NOT NULL,
                PRIMARY KEY (epoch_number, input_index_in_epoch)
            );",
            (),
        )?;
        // machine state hashes table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS machine_state_hashes (
                epoch_number INTEGER NOT NULL,
                input_index_in_epoch INTEGER NOT NULL,
                machine_state_hash BLOB NOT NULL,
                PRIMARY KEY (epoch_number, input_index_in_epoch)
            );",
            (),
        )?;
        // snapshots table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS snapshots (
                epoch_number INTEGER NOT NULL,
                input_index_in_epoch INTEGER NOT NULL,
                path TEXT NOT NULL,
                PRIMARY KEY (epoch_number, input_index_in_epoch)
            );",
            (),
        )?;

        Ok(Self { connection })
    }

    // TODO: fn add_epoch, update_epoch

    pub fn add_input(
        &self,
        input: &[u8],
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<()> {
        // to keep the integrity of the inputs table, an input is only inserted when
        // 1. no input from later epoch exists
        // 2. all prior inputs of the same epoch are added
        let mut sttm = self
            .connection
            .prepare("SELECT count(*) FROM inputs WHERE epoch_number > ?1")?;

        match sttm.query([epoch_number])?.next() {
            Ok(Some(r)) => {
                let count_of_inputs: u64 = r.get(0)?;
                if count_of_inputs > 0 {
                    return Err(anyhow::anyhow!("inputs from later epochs are found"));
                }
            }
            Ok(None) => {
                return Err(anyhow::anyhow!("fail to get count(*) from epoch check"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }

        let mut sttm = self.connection.prepare(
            "SELECT count(*) FROM inputs WHERE epoch_number = ?1 AND input_index_in_epoch < ?2",
        )?;

        match sttm.query([epoch_number, input_index_in_epoch])?.next() {
            Ok(Some(r)) => {
                let count_of_inputs: u64 = r.get(0)?;
                if count_of_inputs != input_index_in_epoch {
                    return Err(anyhow::anyhow!("missing inputs before the current one"));
                }
            }
            Ok(None) => {
                return Err(anyhow::anyhow!(
                    "fail to get count(*) from input index check"
                ));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }

        let mut sttm = self.connection.prepare(
            "
                INSERT INTO inputs (epoch_number, input_index_in_epoch, input) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, input))? != 1 {
            return Err(anyhow::anyhow!("input insertion failed"));
        }
        Ok(())
    }

    pub fn add_machine_state_hash(
        &self,
        machine_state_hash: &[u8],
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<()> {
        // add machine state hash
        // 1. successful if the row doesn't exist
        // 2. do nothing if it exists and the state hash is the same
        // 3. return error if it exists with different state hash
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM machine_state_hashes WHERE epoch_number = ?1 AND input_index_in_epoch = ?2")?;

        match sttm.query([epoch_number, input_index_in_epoch])?.next() {
            Ok(Some(r)) => {
                let read_machine_state_hash: Vec<u8> = r.get(0)?;
                if read_machine_state_hash != machine_state_hash.to_vec() {
                    return Err(anyhow::anyhow!(
                        "different machine state hash exists for the same key"
                    ));
                }
            }
            Ok(None) => {
                // machine state hash doesn't exist
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }

        let mut sttm = self.connection.prepare(
            "INSERT INTO machine_state_hashes (epoch_number, input_index_in_epoch, machine_state_hash) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, machine_state_hash))? != 1 {
            return Err(anyhow::anyhow!("machine state hash insertion failed"));
        }
        Ok(())
    }

    pub fn add_snapshot(
        &self,
        path: &str,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<()> {
        let mut sttm = self.connection.prepare(
            "INSERT INTO snapshots (epoch_number, input_index_in_epoch, path) VALUES (?1, ?2, ?3)",
        )?;

        if sttm.execute((epoch_number, input_index_in_epoch, path))? != 1 {
            return Err(anyhow::anyhow!("machine snapshot insertion failed"));
        }
        Ok(())
    }

    pub fn input(&self, epoch_number: u64, input_index_in_epoch: u64) -> Result<Vec<u8>> {
        let mut sttm = self.connection.prepare(
            "SELECT input FROM inputs WHERE epoch_number = ?1 AND input_index_in_epoch = ?2",
        )?;
        let mut query = sttm.query([epoch_number, input_index_in_epoch])?;

        match query.next() {
            Ok(Some(r)) => {
                let input = r.get(0)?;
                return Ok(input);
            }
            Ok(None) => {
                return Err(anyhow::anyhow!("input doesn't exist"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn machine_state_hash(
        &self,
        epoch_number: u64,
        input_index_in_epoch: u64,
    ) -> Result<Vec<u8>> {
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM machine_state_hashes WHERE epoch_number = ?1 AND input_index_in_epoch = ?2")?;
        let mut query = sttm.query([epoch_number, input_index_in_epoch])?;

        match query.next() {
            Ok(Some(r)) => {
                let state = r.get(0)?;
                return Ok(state);
            }
            Ok(None) => {
                return Err(anyhow::anyhow!("machine state hash doesn't exist"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
        let mut sttm = self.connection.prepare(
            "SELECT epoch_number, input_index_in_epoch, path FROM snapshots \
                ORDER BY \
                    epoch_number DESC, \
                    input_index_in_epoch DESC \
                LIMIT 1",
        )?;
        let mut query = sttm.query([])?;

        match query.next() {
            Ok(Some(r)) => {
                let epoch_number = r.get(0)?;
                let input_index_in_epoch = r.get(1)?;
                let path = r.get(2)?;

                return Ok(Some((path, epoch_number, input_index_in_epoch)));
            }
            Ok(None) => {
                return Ok(None);
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn set_latest_block(&self, block: u64) -> Result<()> {
        let mut sttm = self
            .connection
            .prepare("INSERT OR REPLACE INTO constants (key, value) VALUES (?1, ?2)")?;

        if sttm.execute(("latest_block", block))? != 1 {
            return Err(anyhow::anyhow!("fail to update latest processed block"));
        }
        Ok(())
    }

    pub fn latest_block(&self) -> Result<Option<u64>> {
        let mut sttm = self.connection.prepare(
            "SELECT value FROM constants \
                WHERE key = ?1 ",
        )?;
        let mut query = sttm.query(["latest_block"])?;

        match query.next() {
            Ok(Some(r)) => {
                let latest_block: u64 = r.get::<_, String>(0)?.parse()?;

                return Ok(Some(latest_block));
            }
            Ok(None) => {
                return Ok(None);
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }
}

#[test]

fn test_state_manager() -> Result<()> {
    let db_path = std::env::var("DB_PATH").expect("DB_PATH is not set");

    let input_0_bytes = b"hello";
    let input_1_bytes = b"world";

    let manager = StateManager::connect(&db_path)?;

    manager.add_input(input_0_bytes, 0, 0)?;
    manager.add_input(input_1_bytes, 0, 1)?;

    assert_eq!(
        manager.input(0, 0)?,
        input_0_bytes.to_vec(),
        "input 0 bytes should match"
    );
    assert_eq!(
        manager.input(0, 1)?,
        input_1_bytes.to_vec(),
        "input 1 bytes should match"
    );
    assert_eq!(
        manager.input(0, 2).is_err(),
        true,
        "input 2 shouldn't exist"
    );

    assert_eq!(
        manager.add_input(input_0_bytes, 0, 1).is_err(),
        true,
        "duplicate input index should fail"
    );
    assert_eq!(
        manager.add_input(input_1_bytes, 0, 3).is_err(),
        true,
        "input index should be sequential"
    );
    assert_eq!(
        manager.add_input(input_1_bytes, 0, 2).is_ok(),
        true,
        "add sequential input should succeed"
    );

    assert_eq!(
        manager.latest_block()?.is_none(),
        true,
        "latest block should be empty"
    );

    let latest_block = 20;

    manager.set_latest_block(latest_block)?;

    assert_eq!(
        manager.latest_block()?.expect("latest block should exists"),
        latest_block,
        "latest block should match"
    );

    assert_eq!(
        manager.latest_snapshot()?.is_none(),
        true,
        "latest snapshot should be empty"
    );

    let (latest_snapshot, epoch_number, input_index_in_epoch) = ("AAA", 0, 0);

    manager.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

    assert_eq!(
        manager
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

    manager.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

    assert_eq!(
        manager
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

    manager.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

    assert_eq!(
        manager
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

    manager.add_snapshot(latest_snapshot, epoch_number, input_index_in_epoch)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (
            latest_snapshot.to_string(),
            epoch_number,
            input_index_in_epoch
        ),
        "latest snapshot should match"
    );

    manager.add_snapshot("EEE", 0, 4)?;

    assert_eq!(
        manager
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
