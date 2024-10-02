// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::db::{
    sql::{dispute_data, error::*, migrations},
    Input,
};

use log::info;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Deserializer, Serialize};
use std::sync::Mutex;

#[derive(Debug, Serialize)]
pub struct InputsAndLeafs {
    inputs: Vec<Vec<u8>>,
    leafs: Vec<(Vec<u8>, u64)>,
}

impl<'de> Deserialize<'de> for InputsAndLeafs {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        // Create a temporary struct to deserialize the data
        #[derive(Deserialize)]
        struct TempInputsAndLeafs {
            leafs: Vec<TempLeaf>,        // Use a temporary struct for deserialization
            inputs: Option<Vec<String>>, // Temporarily keep inputs as vec of String
        }

        #[derive(Deserialize)]
        struct TempLeaf {
            hash: String,
            repetitions: u64,
        }

        let temp: TempInputsAndLeafs = TempInputsAndLeafs::deserialize(deserializer)?;

        // Default inputs to an empty vector if it is None
        let inputs = temp.inputs.unwrap_or_else(|| Vec::new());

        // Convert TempLeaf to the desired tuple format
        let leafs = temp
            .leafs
            .into_iter()
            .map(|leaf| {
                let hex_string = leaf.hash.strip_prefix("0x").unwrap_or(&leaf.hash);
                (hex::decode(hex_string).unwrap(), leaf.repetitions)
            })
            .collect();
        // Convert TempInput
        let inputs = inputs
            .into_iter()
            .map(|input| {
                let hex_string = input.strip_prefix("0x").unwrap_or(&input);
                hex::decode(hex_string).unwrap()
            })
            .collect();

        Ok(InputsAndLeafs { leafs, inputs })
    }
}

#[derive(Debug)]
pub struct DisputeStateAccess {
    connection: Mutex<Connection>,
}

use std::fs::File;
use std::io::Read;

fn read_json_file(file_path: &str) -> Result<InputsAndLeafs> {
    let mut file = File::open(file_path)?;
    let mut contents = String::new();
    file.read_to_string(&mut contents)?;
    let data: InputsAndLeafs = serde_json::from_str(&contents)?;
    Ok(data)
}

impl DisputeStateAccess {
    pub fn new(
        inputs: Vec<Vec<u8>>,
        leafs: Vec<(Vec<u8>, u64)>,
        root_tournament: String,
    ) -> Result<Self> {
        // initialize the database if it doesn't exist
        // fill the database from a json-format file, or the parameters
        // the database should be "/dispute_data/0x_root_tournament_address/db"
        // the json file should be "/dispute_data/0x_root_tournament_address/inputs_and_leafs.json"
        let db_path = format!("/dispute_data/{root_tournament}/db");
        let no_create_flags = OpenFlags::default() & !OpenFlags::SQLITE_OPEN_CREATE;
        match Connection::open_with_flags(&db_path, no_create_flags) {
            // database already exists, return it
            Ok(connection) => {
                return Ok(Self {
                    connection: Mutex::new(connection),
                })
            }
            Err(_) => {
                // create new database
                info!("create new database");
                let mut connection = Connection::open(&db_path)?;
                migrations::migrate_to_latest(&mut connection).unwrap();

                let json_path = format!("/dispute_data/{root_tournament}/inputs_and_leafs.json");
                // prioritize json file over parameters
                match read_json_file(&json_path) {
                    Ok(inputs_and_leafs) => {
                        dispute_data::insert_dispute_data(
                            &connection,
                            inputs_and_leafs.inputs.iter(),
                            inputs_and_leafs.leafs.iter(),
                        )?;
                    }
                    Err(_) => {
                        info!("load inputs and leafs from parameters");
                        dispute_data::insert_dispute_data(
                            &connection,
                            inputs.iter(),
                            leafs.iter(),
                        )?;
                    }
                }

                Ok(Self {
                    connection: Mutex::new(connection),
                })
            }
        }
    }

    pub fn input(&self, id: u64) -> Result<Option<Input>> {
        let conn = self.connection.lock().unwrap();
        dispute_data::input(&conn, id)
    }

    pub fn compute_leafs(&self, level: u64, base_cycle: u64) -> Result<Vec<(Vec<u8>, u64)>> {
        let conn = self.connection.lock().unwrap();
        dispute_data::compute_leafs(&conn, level, base_cycle)
    }

    // fn add_snapshot(&self, path: &str, epoch_number: u64, input_index: u64) -> Result<()> {
    //     let conn = self.connection.lock().unwrap();
    //     let mut sttm = conn.prepare(
    //         "INSERT INTO snapshots (epoch_number, input_index, path) VALUES (?1, ?2, ?3)",
    //     )?;

    //     if sttm.execute((epoch_number, input_index, path))? != 1 {
    //         return Err(DisputeStateAccessError::InsertionFailed {
    //             description: "machine snapshot insertion failed".to_owned(),
    //         });
    //     }
    //     Ok(())
    // }

    // fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
    //     let conn = self.connection.lock().unwrap();
    //     let mut sttm = conn.prepare(
    //         "\
    //         SELECT epoch_number, input_index, path FROM snapshots
    //         ORDER BY epoch_number DESC, input_index DESC LIMIT 1
    //         ",
    //     )?;
    //     let mut query = sttm.query([])?;

    //     match query.next()? {
    //         Some(r) => {
    //             let epoch_number = r.get(0)?;
    //             let input_index = r.get(1)?;
    //             let path = r.get(2)?;

    //             Ok(Some((path, epoch_number, input_index)))
    //         }
    //         None => Ok(None),
    //     }
    // }

    // fn snapshot(&self, epoch_number: u64, input_index: u64) -> Result<Option<String>> {
    //     let conn = self.connection.lock().unwrap();
    //     let mut sttm = conn.prepare(
    //         "\
    //         SELECT path FROM snapshots
    //         WHERE epoch_number = ?1
    //         AND input_index = ?2
    //         ",
    //     )?;

    //     Ok(sttm
    //         .query_row([epoch_number, input_index], |row| Ok(row.get(0)?))
    //         .optional()?)
    // }
}

// TODO: add tests
