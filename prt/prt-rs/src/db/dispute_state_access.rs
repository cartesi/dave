// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::db::{
    sql::{dispute_data, error::*, migrations},
    Input,
};
use cartesi_dave_merkle::{Digest, MerkleBuilder, MerkleTree};

use log::info;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Deserializer, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

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
    pub work_path: PathBuf,
}

use std::fs::File;
use std::io::Read;

fn read_json_file(file_path: &Path) -> Result<InputsAndLeafs> {
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
        let work_dir = format!("/dispute_data/{root_tournament}");
        let work_path = PathBuf::from(work_dir);
        let db_path = work_path.join("db");
        let no_create_flags = OpenFlags::default() & !OpenFlags::SQLITE_OPEN_CREATE;
        match Connection::open_with_flags(&db_path, no_create_flags) {
            // database already exists, return it
            Ok(connection) => {
                return Ok(Self {
                    connection: Mutex::new(connection),
                    work_path,
                })
            }
            Err(_) => {
                // create new database
                info!("create new database");
                let mut connection = Connection::open(&db_path)?;
                migrations::migrate_to_latest(&mut connection).unwrap();

                let json_path = work_path.join("inputs_and_leafs.json");
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
                    work_path,
                })
            }
        }
    }

    pub fn input(&self, id: u64) -> Result<Option<Input>> {
        let conn = self.connection.lock().unwrap();
        dispute_data::input(&conn, id)
    }

    pub fn insert_compute_leafs<'a>(
        &self,
        level: u64,
        base_cycle: u64,
        leafs: impl Iterator<Item = &'a (Vec<u8>, u64)>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        dispute_data::insert_compute_leafs(&conn, level, base_cycle, leafs)
    }

    pub fn compute_leafs(
        &self,
        level: u64,
        base_cycle: u64,
    ) -> Result<Vec<(Arc<MerkleTree>, u64)>> {
        let conn = self.connection.lock().unwrap();
        let leafs = dispute_data::compute_leafs(&conn, level, base_cycle)?;

        let mut tree = Vec::new();
        for leaf in leafs {
            let tree_leafs = dispute_data::compute_tree(&conn, &leaf.0)?;
            if tree_leafs.len() > 0 {
                // if leaf is also tree, rebuild it from nested leafs
                let mut builder = MerkleBuilder::default();
                for tree_leaf in tree_leafs {
                    builder.append_repeated(Digest::from_digest(&tree_leaf.0)?, tree_leaf.1);
                }
                tree.push((builder.build(), leaf.1));
            } else {
                tree.push((Digest::from_digest(&leaf.0)?.into(), leaf.1));
            }
        }

        Ok(tree)
    }

    pub fn insert_compute_tree<'a>(
        &self,
        tree_root: &[u8],
        tree_leafs: impl Iterator<Item = &'a (Vec<u8>, u64)>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        dispute_data::insert_compute_tree(&conn, tree_root, tree_leafs)
    }

    pub fn closest_snapshot(&self, base_cycle: u64) -> Result<Option<PathBuf>> {
        let mut snapshots = Vec::new();

        // iterate through the snapshot directory, find the one whose cycle number is closest to the base_cycle
        for entry in fs::read_dir(&self.work_path)? {
            let entry = entry?;
            let path = entry.path();

            if path.is_dir() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if name.chars().all(char::is_numeric) {
                        if let Ok(number) = name.parse::<u64>() {
                            snapshots.push((number, path));
                        }
                    }
                }
            }
        }

        snapshots.sort_by_key(|k| k.0);
        let pos = snapshots
            .binary_search_by_key(&base_cycle, |k| k.0)
            .unwrap_or_else(|x| if x > 0 { x - 1 } else { x });

        Ok(snapshots.get(pos).map(|t| t.1.clone()))
    }
}

// TODO: add tests
