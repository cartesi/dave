// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{
    db::sql::{dispute_data, error::*, migrations},
    machine::constants,
};
use cartesi_dave_arithmetic::max_uint;
use cartesi_dave_merkle::{Digest, MerkleBuilder, MerkleTree};

use alloy::{hex as alloy_hex, primitives::U256};
use log::info;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

#[derive(Debug, Serialize, Deserialize)]
pub struct InputsAndLeafs {
    inputs: Vec<Input>,
    leafs: Vec<Leaf>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct Input(#[serde(with = "alloy_hex::serde")] pub Vec<u8>);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Leaf {
    #[serde(with = "alloy_hex::serde")]
    pub hash: [u8; 32],
    pub repetitions: u64,
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
        inputs: Vec<Input>,
        leafs: Vec<Leaf>,
        _root_tournament: String,
        compute_data_path: PathBuf,
    ) -> Result<Self> {
        // initialize the database if it doesn't exist
        // fill the database from a json-format file, or the parameters
        // the database should be "./db"
        // the json file should be "/compute_data/0x_root_tournament_address/inputs_and_leafs.json"
        let work_path = compute_data_path;
        if !work_path.exists() {
            fs::create_dir_all(&work_path)?;
        }
        let db_path = work_path.join("db");
        let no_create_flags = OpenFlags::default() & !OpenFlags::SQLITE_OPEN_CREATE;
        match Connection::open_with_flags(&db_path, no_create_flags) {
            // database already exists, return it
            Ok(connection) => {
                connection
                    .busy_timeout(std::time::Duration::from_secs(10))
                    .map_err(anyhow::Error::from)
                    .unwrap();
                Ok(Self {
                    connection: Mutex::new(connection),
                    work_path,
                })
            }
            Err(_) => {
                info!("create new database for dispute");
                let mut connection = Connection::open(&db_path)?;
                migrations::migrate_to_latest(&mut connection).unwrap();
                connection
                    .busy_timeout(std::time::Duration::from_secs(10))
                    .map_err(anyhow::Error::from)
                    .unwrap();

                let json_path = work_path.join("inputs_and_leafs.json");
                // prioritize json file over parameters
                match read_json_file(&json_path) {
                    Ok(inputs_and_leafs) => {
                        info!("load inputs and leafs from json file");
                        dispute_data::insert_compute_data(
                            &connection,
                            inputs_and_leafs.inputs.iter(),
                            inputs_and_leafs.leafs.iter(),
                        )?;
                    }
                    Err(_) => {
                        info!("load inputs and leafs from parameters");
                        dispute_data::insert_compute_data(
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

    pub fn input(&self, id: u64) -> Result<Option<Vec<u8>>> {
        let conn = self.connection.lock().unwrap();
        dispute_data::input(&conn, id)
    }

    pub fn inputs(&self) -> Result<Vec<Vec<u8>>> {
        let conn = self.connection.lock().unwrap();
        dispute_data::inputs(&conn)
    }

    pub fn insert_leafs<'a>(
        &self,
        level: u64,
        base_cycle: U256,
        leafs: impl Iterator<Item = &'a Leaf>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        dispute_data::insert_leafs(&conn, level, base_cycle, leafs)
    }

    pub fn leafs(
        &self,
        level: u64,
        log2_stride: u64,
        log2_stride_count: u64,
        base_cycle: U256,
    ) -> Result<Vec<(Arc<MerkleTree>, u64)>> {
        let conn = self.connection.lock().unwrap();
        let leafs = dispute_data::leafs(&conn, level, base_cycle)?;

        let mut tree = Vec::new();
        if log2_stride == 0 && !leafs.is_empty() {
            tree = self.leafs_with_uarch(leafs, log2_stride_count)?;
        } else {
            for (leaf, repetitions) in leafs {
                tree.push((Digest::from_digest(&leaf)?.into(), repetitions));
            }
        }

        Ok(tree)
    }

    fn leafs_with_uarch(
        &self,
        leafs: Vec<(Vec<u8>, u64)>,
        log2_stride_count: u64,
    ) -> Result<Vec<(Arc<MerkleTree>, u64)>> {
        let mut main_tree = Vec::new();
        let span_count = max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN_TO_BARCH) + 1;
        let span_size = constants::UARCH_SPAN_TO_BARCH + 1;
        let mut accumulated_repetitions = 0;
        let mut uarch_tree_builder = MerkleBuilder::default();

        for (leaf, repetitions) in leafs {
            if accumulated_repetitions == 0 {
                // reset the uarch_tree builder
                uarch_tree_builder = MerkleBuilder::default();
            }

            if accumulated_repetitions < span_size {
                uarch_tree_builder.append_repeated(Digest::from_digest(&leaf)?, repetitions);
                accumulated_repetitions += repetitions;
            }
            if accumulated_repetitions == span_size {
                // here we build a uarch_tree and add it to the main tree
                main_tree.push((uarch_tree_builder.build(), 1));
                // reset the accumulated repetitions
                accumulated_repetitions = 0;
            }
        }

        assert!(main_tree.len() > 0);
        let main_tree_len = main_tree.len() as u64;
        if main_tree_len < span_count {
            main_tree.push((uarch_tree_builder.build(), span_count - main_tree_len));
        }

        Ok(main_tree)
    }

    /*
    pub fn closest_snapshot(&self, base_cycle: u64) -> Result<Option<(u64, PathBuf)>> {
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

        let snapshot = {
            match snapshots.get(pos) {
                Some(t) => {
                    if t.0 > base_cycle {
                        None
                    } else {
                        Some(t.clone())
                    }
                }
                // snapshots.get(pos).map(|t| t.clone()),
                None => None,
            }
        };

        Ok(snapshot)
    }
    */
}

#[cfg(test)]
mod compute_state_access_tests {
    use super::*;

    #[test]
    fn test_access_sequentially() {
        // test_closest_snapshot();
        // test_none_match();
    }

    /*
    fn test_closest_snapshot() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        {
            let access = DisputeStateAccess::new(
                None,
                Vec::new(),
                String::from("12345678"),
                PathBuf::from("/tmp"),
            )
            .unwrap();

            assert_eq!(access.closest_snapshot(0).unwrap(), None);
            assert_eq!(access.closest_snapshot(100).unwrap(), None);
            assert_eq!(access.closest_snapshot(150).unwrap(), None);
            assert_eq!(access.closest_snapshot(200).unwrap(), None);
            assert_eq!(access.closest_snapshot(300).unwrap(), None);
            assert_eq!(access.closest_snapshot(9000).unwrap(), None);
            assert_eq!(access.closest_snapshot(9999).unwrap(), None);

            for cycle in [99999, 0, 1, 5, 99, 300, 150, 200] {
                create_directory(&access.work_path.join(format!("{cycle}"))).unwrap();
            }

            assert_eq!(
                access.closest_snapshot(100).unwrap(),
                Some((99, access.work_path.join("99")))
            );

            assert_eq!(
                access.closest_snapshot(150).unwrap(),
                Some((150, access.work_path.join("150")))
            );

            assert_eq!(
                access.closest_snapshot(200).unwrap(),
                Some((200, access.work_path.join("200")))
            );

            assert_eq!(
                access.closest_snapshot(300).unwrap(),
                Some((300, access.work_path.join("300")))
            );

            assert_eq!(
                access.closest_snapshot(7).unwrap(),
                Some((5, access.work_path.join("5")))
            );

            assert_eq!(
                access.closest_snapshot(10000).unwrap(),
                Some((300, access.work_path.join("300")))
            );

            assert_eq!(
                access.closest_snapshot(100000).unwrap(),
                Some((99999, access.work_path.join("99999")))
            );
        }

        remove_directory(&work_dir).unwrap();
    }

    fn test_none_match() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        {
            let access = DisputeStateAccess::new(
                None,
                Vec::new(),
                String::from("12345678"),
                PathBuf::from("/tmp"),
            )
            .unwrap();

            let cycle: u64 = 844424930131968;
            {
                let c = cycle;
                create_directory(&access.work_path.join(format!("{c}"))).unwrap();
            }

            assert_eq!(access.closest_snapshot(0).unwrap(), None);
            assert_eq!(access.closest_snapshot(5629).unwrap(), None);
            assert_eq!(access.closest_snapshot(5629499).unwrap(), None);
            assert_eq!(access.closest_snapshot(56294995342).unwrap(), None);
            assert_eq!(access.closest_snapshot(562949953421312).unwrap(), None);
            assert_eq!(
                access.closest_snapshot(cycle).unwrap(),
                Some((cycle, access.work_path.join(format!("{}", cycle))))
            );
            assert_eq!(
                access.closest_snapshot(cycle + 1).unwrap(),
                Some((cycle, access.work_path.join(format!("{}", cycle))))
            );

            remove_directory(&work_dir).unwrap();
        }
    }
    */

    #[test]
    fn test_deserialize() {
        let json_str_1 = r#"{"inputs": [], "leafs": [
            {"hash":"0x01020304050607abcdef01020304050607abcdef01020304050607abcdef0102", "repetitions":20}, 
            {"hash":"0x01020304050607fedcba01020304050607fedcba01020304050607fedcba0102", "repetitions":13}]}"#;
        let inputs_and_leafs_1: InputsAndLeafs = serde_json::from_str(json_str_1).unwrap();
        assert_eq!(inputs_and_leafs_1.inputs.len(), 0);
        assert_eq!(inputs_and_leafs_1.leafs.len(), 2);
        assert_eq!(
            inputs_and_leafs_1.leafs[0].hash,
            [
                1, 2, 3, 4, 5, 6, 7, 171, 205, 239, 1, 2, 3, 4, 5, 6, 7, 171, 205, 239, 1, 2, 3, 4,
                5, 6, 7, 171, 205, 239, 1, 2
            ]
        );
        assert_eq!(
            inputs_and_leafs_1.leafs[1].hash,
            [
                1, 2, 3, 4, 5, 6, 7, 254, 220, 186, 1, 2, 3, 4, 5, 6, 7, 254, 220, 186, 1, 2, 3, 4,
                5, 6, 7, 254, 220, 186, 1, 2
            ]
        );

        let json_str_2 = r#"{"inputs": [], "leafs": [
            {"hash":"0x01020304050607abcdef01020304050607abcdef01020304050607abcdef0102", "repetitions": 20}, 
            {"hash":"0x01020304050607fedcba01020304050607fedcba01020304050607fedcba0102", "repetitions": 13}]}"#;
        let inputs_and_leafs_2: InputsAndLeafs = serde_json::from_str(json_str_2).unwrap();
        assert_eq!(inputs_and_leafs_2.inputs.len(), 0);
        assert_eq!(inputs_and_leafs_2.leafs.len(), 2);

        let json_str_3 = r#"{"inputs": ["0x12345678", "0x22345678"], "leafs": [
            {"hash":"0x01020304050607abcdef01020304050607abcdef01020304050607abcdef0102", "repetitions": 20}, 
            {"hash":"0x01020304050607fedcba01020304050607fedcba01020304050607fedcba0102", "repetitions": 13}]}"#;
        let inputs_and_leafs_3: InputsAndLeafs = serde_json::from_str(json_str_3).unwrap();
        let inputs_3 = inputs_and_leafs_3.inputs;
        assert_eq!(inputs_3.len(), 2);
        assert_eq!(inputs_and_leafs_3.leafs.len(), 2);
        assert_eq!(inputs_3[0].0, [18, 52, 86, 120]);
        assert_eq!(inputs_3[1].0, [34, 52, 86, 120]);
    }
}
