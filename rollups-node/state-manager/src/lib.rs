// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::Result;
use sqlite::State;

pub struct StateManager {
    connection: sqlite::ConnectionThreadSafe,
}

impl StateManager {
    pub fn connect(database_uri: &str) -> Result<Self> {
        let connection = sqlite::Connection::open_thread_safe(database_uri)?;
        // constants table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS constants (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL
            );",
        )?;
        // epochs table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS epochs (
                epoch_number INTEGER NOT NULL PRIMARY KEY,
                sealed INTEGER,
                settled BOOLEAN NOT NULL
            );",
        )?;
        // inputs table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS inputs (
                epoch_number INTEGER NOT NULL,
                input_index INTEGER NOT NULL,
                input BLOB NOT NULL,
                PRIMARY KEY (epoch_number, input_index)
            );",
        )?;
        // states table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS states (
                epoch_number INTEGER NOT NULL,
                input_index INTEGER NOT NULL,
                state BLOB NOT NULL,
                PRIMARY KEY (epoch_number, input_index)
            );",
        )?;
        // snapshots table
        connection.execute(
            "CREATE TABLE IF NOT EXISTS snapshots (
                epoch_number INTEGER NOT NULL,
                input_index INTEGER NOT NULL,
                path TEXT NOT NULL,
                PRIMARY KEY (epoch_number, input_index)
            );",
        )?;

        Ok(Self { connection })
    }

    // TODO: fn add_epoch, update_epoch

    pub fn add_input(&self, input: &[u8], epoch_number: u64, input_index: u64) -> Result<()> {
        // to keep the integrity of the inputs table, an input is only inserted when
        // 1. no input from later epoch exists
        // 2. all prior inputs of the same epoch are added
        let mut sttm = self
            .connection
            .prepare("SELECT count(*) FROM inputs WHERE epoch_number > ?")?;
        sttm.bind((1, epoch_number as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                if sttm.read::<i64, _>("count(*)")? > 0 {
                    return Err(anyhow::anyhow!("inputs from later epochs are found"));
                }
            }
            Ok(State::Done) => {
                return Err(anyhow::anyhow!("fail to get count(*) from epoch check"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }

        let mut sttm = self
            .connection
            .prepare("SELECT count(*) FROM inputs WHERE epoch_number = ? AND input_index < ?")?;
        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                if sttm.read::<i64, _>("count(*)")? != input_index as i64 {
                    return Err(anyhow::anyhow!("missing inputs before the current one"));
                }
            }
            Ok(State::Done) => {
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
                INSERT INTO inputs (epoch_number, input_index, input) VALUES (?, ?, ?)",
        )?;

        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;
        sttm.bind((3, input))?;

        match sttm.next() {
            Ok(State::Row) => {
                return Err(anyhow::anyhow!("unknown row received from input insertion"));
            }
            Ok(State::Done) => {
                return Ok(());
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn add_state(&self, state: &[u8], epoch_number: u64, input_index: u64) -> Result<()> {
        // add state
        // 1. successful if the state doesn't exist
        // 2. do nothing if it exists and the state is the same
        // 3. return error if it exists with different value
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM states WHERE epoch_number = ? AND input_index = ?")?;
        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                if sttm.read::<Vec<u8>, _>("state")? != state.to_vec() {
                    return Err(anyhow::anyhow!("different state exists for the same key"));
                }
                return Ok(());
            }
            Ok(State::Done) => {
                // state doesn't exist
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }

        let mut sttm = self
            .connection
            .prepare("INSERT INTO states (epoch_number, input_index, state) VALUES (?, ?, ?)")?;

        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;
        sttm.bind((3, state))?;

        match sttm.next() {
            Ok(State::Row) => {
                return Err(anyhow::anyhow!("unknown row received from state insertion"));
            }
            Ok(State::Done) => {
                return Ok(());
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn add_snapshot(&self, path: &str, epoch_number: u64, input_index: u64) -> Result<()> {
        let mut sttm = self
            .connection
            .prepare("INSERT INTO snapshots (epoch_number, input_index, path) VALUES (?, ?, ?)")?;

        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;
        sttm.bind((3, path))?;

        match sttm.next() {
            Ok(State::Row) => {
                return Err(anyhow::anyhow!(
                    "unknown row received from snapshot insertion"
                ));
            }
            Ok(State::Done) => {
                return Ok(());
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn input(&self, epoch_number: u64, input_index: u64) -> Result<Vec<u8>> {
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM inputs WHERE epoch_number = ? AND input_index = ?")?;
        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                let input = sttm.read::<Vec<u8>, _>("input")?;
                return Ok(input);
            }
            Ok(State::Done) => {
                return Err(anyhow::anyhow!("input doesn't exist"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn state(&self, epoch_number: u64, input_index: u64) -> Result<Vec<u8>> {
        let mut sttm = self
            .connection
            .prepare("SELECT * FROM states WHERE epoch_number = ? AND input_index = ?")?;
        sttm.bind((1, epoch_number as i64))?;
        sttm.bind((2, input_index as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                let state = sttm.read::<Vec<u8>, _>("state")?;
                return Ok(state);
            }
            Ok(State::Done) => {
                return Err(anyhow::anyhow!("state doesn't exist"));
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
        let mut sttm = self.connection.prepare(
            "SELECT * FROM snapshots \
                ORDER BY \
                    epoch_number DESC, \
                    input_index DESC \
                LIMIT 1",
        )?;

        match sttm.next() {
            Ok(State::Row) => {
                let epoch_number = sttm.read::<i64, _>("epoch_number")?;
                let input_index = sttm.read::<i64, _>("input_index")?;
                let path = sttm.read::<String, _>("path")?;

                return Ok(Some((path, epoch_number as u64, input_index as u64)));
            }
            Ok(State::Done) => {
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
            .prepare("INSERT INTO constants (key, value) VALUES (?, ?)")?;

        sttm.bind((1, "latest_block"))?;
        sttm.bind((2, block as i64))?;

        match sttm.next() {
            Ok(State::Row) => {
                return Err(anyhow::anyhow!(
                    "unknown row received from latest block update"
                ));
            }
            Ok(State::Done) => {
                return Ok(());
            }
            Err(e) => {
                return Err(anyhow::anyhow!(e.to_string()));
            }
        }
    }

    pub fn latest_block(&self) -> Result<Option<u64>> {
        let mut sttm = self.connection.prepare(
            "SELECT * FROM constants \
                WHERE key = \"latest_block\" ",
        )?;

        match sttm.next() {
            Ok(State::Row) => {
                let latest_block = sttm.read::<i64, _>("value")?;

                return Ok(Some(latest_block as u64));
            }
            Ok(State::Done) => {
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

    let (latest_snapshot, epoch_number, input_index) = ("AAA", 0, 0);

    manager.add_snapshot(latest_snapshot, epoch_number, input_index)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (latest_snapshot.to_string(), epoch_number, input_index),
        "latest snapshot should match"
    );

    let (latest_snapshot, epoch_number, input_index) = ("BBB", 0, 1);

    manager.add_snapshot(latest_snapshot, epoch_number, input_index)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (latest_snapshot.to_string(), epoch_number, input_index),
        "latest snapshot should match"
    );

    let (latest_snapshot, epoch_number, input_index) = ("CCC", 0, 2);

    manager.add_snapshot(latest_snapshot, epoch_number, input_index)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (latest_snapshot.to_string(), epoch_number, input_index),
        "latest snapshot should match"
    );

    let (latest_snapshot, epoch_number, input_index) = ("DDD", 3, 1);

    manager.add_snapshot(latest_snapshot, epoch_number, input_index)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (latest_snapshot.to_string(), epoch_number, input_index),
        "latest snapshot should match"
    );

    manager.add_snapshot("EEE", 0, 4)?;

    assert_eq!(
        manager
            .latest_snapshot()?
            .expect("latest snapshot should exists"),
        (latest_snapshot.to_string(), epoch_number, input_index),
        "latest snapshot should match"
    );

    Ok(())
}
