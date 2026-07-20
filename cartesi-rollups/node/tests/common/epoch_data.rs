// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute's per-epoch material, held in memory. Inputs are read
//! out of the node database and passed by value; the durable dispute
//! state is the quartet cache, so nothing here needs its own
//! persistence. `work_path` is the epoch's scratch directory for
//! dispute-time machine snapshots (stored by root hash).

use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Leaf {
    pub hash: [u8; 32],
    pub repetitions: u64,
}

#[derive(Debug)]
pub struct EpochData {
    inputs: Vec<Vec<u8>>,
    pub work_path: PathBuf,
}

impl EpochData {
    pub fn new(inputs: Vec<Vec<u8>>, work_path: PathBuf) -> std::io::Result<Self> {
        std::fs::create_dir_all(&work_path)?;
        Ok(Self { inputs, work_path })
    }

    pub fn input(&self, id: u64) -> Option<Vec<u8>> {
        self.inputs.get(id as usize).cloned()
    }
}
