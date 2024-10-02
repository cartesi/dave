// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod dispute_state_access;

pub(crate) mod sql;

#[derive(Clone, Debug)]
pub struct Input {
    pub id: u64,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct StateHash {
    pub id: u64,
    pub data: Vec<u8>,
    pub repetition: u64,
}
