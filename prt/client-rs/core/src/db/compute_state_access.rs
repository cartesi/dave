// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::db::sql::{compute_data, error::*, migrations};
use cartesi_dave_merkle::{Digest, MerkleBuilder, MerkleTree};

use alloy::hex as alloy_hex;
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
    inputs: Option<Vec<Input>>,
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
pub struct ComputeStateAccess {
    connection: Mutex<Connection>,
    pub handle_rollups: bool,
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

impl ComputeStateAccess {
    pub fn new(
        inputs: Option<Vec<Input>>,
        leafs: Vec<Leaf>,
        root_tournament: String,
        compute_data_path: PathBuf,
    ) -> Result<Self> {
        // initialize the database if it doesn't exist
        // fill the database from a json-format file, or the parameters
        // the database should be "/compute_data/0x_root_tournament_address/db"
        // the json file should be "/compute_data/0x_root_tournament_address/inputs_and_leafs.json"
        let work_path = compute_data_path.join(root_tournament.to_uppercase());
        if !work_path.exists() {
            fs::create_dir_all(&work_path)?;
        }
        let db_path = work_path.join("db");
        let no_create_flags = OpenFlags::default() & !OpenFlags::SQLITE_OPEN_CREATE;
        let handle_rollups;
        match Connection::open_with_flags(&db_path, no_create_flags) {
            // database already exists, return it
            Ok(connection) => {
                handle_rollups = compute_data::handle_rollups(&connection)?;
                Ok(Self {
                    connection: Mutex::new(connection),
                    handle_rollups,
                    work_path,
                })
            }
            Err(_) => {
                info!("create new database for dispute");
                let mut connection = Connection::open(&db_path)?;
                migrations::migrate_to_latest(&mut connection).unwrap();

                let json_path = work_path.join("inputs_and_leafs.json");
                // prioritize json file over parameters
                match read_json_file(&json_path) {
                    Ok(inputs_and_leafs) => {
                        info!("load inputs and leafs from json file");
                        handle_rollups = inputs_and_leafs.inputs.is_some();
                        compute_data::insert_handle_rollups(&connection, handle_rollups)?;
                        compute_data::insert_compute_data(
                            &connection,
                            inputs_and_leafs.inputs.unwrap_or_default().iter(),
                            inputs_and_leafs.leafs.iter(),
                        )?;
                    }
                    Err(e) => {
                        info!("cannot load from json file: {}", e);
                        info!("load inputs and leafs from parameters");
                        handle_rollups = inputs.is_some();
                        compute_data::insert_handle_rollups(&connection, handle_rollups)?;
                        compute_data::insert_compute_data(
                            &connection,
                            inputs.unwrap_or_default().iter(),
                            leafs.iter(),
                        )?;
                    }
                }

                Ok(Self {
                    connection: Mutex::new(connection),
                    handle_rollups,
                    work_path,
                })
            }
        }
    }

    pub fn input(&self, id: u64) -> Result<Option<Vec<u8>>> {
        let conn = self.connection.lock().unwrap();
        compute_data::input(&conn, id)
    }

    pub fn inputs(&self) -> Result<Vec<Vec<u8>>> {
        let conn = self.connection.lock().unwrap();
        compute_data::inputs(&conn)
    }

    pub fn insert_compute_leafs<'a>(
        &self,
        level: u64,
        base_cycle: u64,
        leafs: impl Iterator<Item = &'a Leaf>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        compute_data::insert_compute_leafs(&conn, level, base_cycle, leafs)
    }

    pub fn compute_leafs(
        &self,
        level: u64,
        base_cycle: u64,
    ) -> Result<Vec<(Arc<MerkleTree>, u64)>> {
        let conn = self.connection.lock().unwrap();
        let leafs = compute_data::compute_leafs(&conn, level, base_cycle)?;

        let mut tree = Vec::new();
        for leaf in leafs {
            let tree_leafs = compute_data::compute_tree(&conn, &leaf.0)?;
            if !tree_leafs.is_empty() {
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

    pub fn insert_compute_trees<'a>(
        &self,
        compute_trees: impl Iterator<Item = &'a (Digest, Vec<Leaf>)>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        let tx = conn.unchecked_transaction()?;
        for digest_and_leaf in compute_trees {
            compute_data::insert_compute_tree(
                &tx,
                digest_and_leaf.0.slice(),
                digest_and_leaf.1.iter(),
            )?;
        }
        tx.commit()?;

        Ok(())
    }

    pub fn insert_compute_tree<'a>(
        &self,
        tree_root: &[u8],
        tree_leafs: impl Iterator<Item = &'a Leaf>,
    ) -> Result<()> {
        let conn = self.connection.lock().unwrap();
        let tx = conn.unchecked_transaction()?;
        compute_data::insert_compute_tree(&tx, tree_root, tree_leafs)?;
        tx.commit()?;

        Ok(())
    }

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
}

#[cfg(test)]
mod compute_state_access_tests {
    use super::*;

    fn create_directory(path: &Path) -> std::io::Result<()> {
        fs::create_dir_all(path)?;
        Ok(())
    }

    fn remove_directory(path: &Path) -> std::io::Result<()> {
        let _ = fs::remove_dir_all(path);
        Ok(())
    }

    #[test]
    fn test_access_sequentially() {
        test_compute_tree();
        test_closest_snapshot();
        test_compute_or_rollups_true();
        test_compute_or_rollups_false();
        test_none_match();
    }

    fn test_closest_snapshot() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        {
            let access = ComputeStateAccess::new(
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
                Some((99, access.work_path.join(format!("99"))))
            );

            assert_eq!(
                access.closest_snapshot(150).unwrap(),
                Some((150, access.work_path.join(format!("150"))))
            );

            assert_eq!(
                access.closest_snapshot(200).unwrap(),
                Some((200, access.work_path.join(format!("200"))))
            );

            assert_eq!(
                access.closest_snapshot(300).unwrap(),
                Some((300, access.work_path.join(format!("300"))))
            );

            assert_eq!(
                access.closest_snapshot(7).unwrap(),
                Some((5, access.work_path.join(format!("5"))))
            );

            assert_eq!(
                access.closest_snapshot(10000).unwrap(),
                Some((300, access.work_path.join(format!("300"))))
            );

            assert_eq!(
                access.closest_snapshot(100000).unwrap(),
                Some((99999, access.work_path.join(format!("99999"))))
            );
        }

        remove_directory(&work_dir).unwrap();
    }

    fn test_none_match() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        {
            let access = ComputeStateAccess::new(
                None,
                Vec::new(),
                String::from("12345678"),
                PathBuf::from("/tmp"),
            )
            .unwrap();

            let cycle: u64 = 844424930131968;
            for c in [cycle] {
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

    fn test_compute_tree() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        let access = ComputeStateAccess::new(
            None,
            Vec::new(),
            String::from("12345678"),
            PathBuf::from("/tmp"),
        )
        .unwrap();

        let root = [
            1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1,
            2, 3, 4,
        ];
        let leafs = vec![Leaf {
            hash: root,
            repetitions: 2,
        }];

        access.insert_compute_leafs(0, 0, leafs.iter()).unwrap();
        let mut compute_leafs = access.compute_leafs(0, 0).unwrap();
        let mut tree = compute_leafs.last().unwrap();
        assert!(tree.0.subtrees().is_none());

        access.insert_compute_tree(&root, leafs.iter()).unwrap();
        compute_leafs = access.compute_leafs(0, 0).unwrap();
        tree = compute_leafs.last().unwrap();
        assert!(tree.0.subtrees().is_some());
    }

    fn test_compute_or_rollups_true() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        let access = ComputeStateAccess::new(
            Some(Vec::new()),
            Vec::new(),
            String::from("12345678"),
            PathBuf::from("/tmp"),
        )
        .unwrap();

        assert!(matches!(access.handle_rollups, true));
    }

    fn test_compute_or_rollups_false() {
        let work_dir = PathBuf::from("/tmp/12345678");
        remove_directory(&work_dir).unwrap();
        create_directory(&work_dir).unwrap();
        let access = ComputeStateAccess::new(
            None,
            Vec::new(),
            String::from("12345678"),
            PathBuf::from("/tmp"),
        )
        .unwrap();

        assert!(matches!(access.handle_rollups, false));
    }

    #[test]
    fn test_deserialize() {
        let json_str_1 = r#"{"leafs": [
            {"hash":"0x01020304050607abcdef01020304050607abcdef01020304050607abcdef0102", "repetitions":20}, 
            {"hash":"0x01020304050607fedcba01020304050607fedcba01020304050607fedcba0102", "repetitions":13}]}"#;
        let inputs_and_leafs_1: InputsAndLeafs = serde_json::from_str(json_str_1).unwrap();
        assert_eq!(inputs_and_leafs_1.inputs.unwrap_or_default().len(), 0);
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
        assert_eq!(inputs_and_leafs_2.inputs.unwrap_or_default().len(), 0);
        assert_eq!(inputs_and_leafs_2.leafs.len(), 2);

        let json_str_3 = r#"{"inputs": ["0x12345678", "0x22345678"], "leafs": [
            {"hash":"0x01020304050607abcdef01020304050607abcdef01020304050607abcdef0102", "repetitions": 20}, 
            {"hash":"0x01020304050607fedcba01020304050607fedcba01020304050607fedcba0102", "repetitions": 13}]}"#;
        let inputs_and_leafs_3: InputsAndLeafs = serde_json::from_str(json_str_3).unwrap();
        let inputs_3 = inputs_and_leafs_3.inputs.unwrap();
        assert_eq!(inputs_3.len(), 2);
        assert_eq!(inputs_and_leafs_3.leafs.len(), 2);
        assert_eq!(inputs_3[0].0, [18, 52, 86, 120]);
        assert_eq!(inputs_3[1].0, [34, 52, 86, 120]);
    }
}
