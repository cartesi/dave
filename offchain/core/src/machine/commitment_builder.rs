//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use std::{collections::HashMap, error::Error, sync::Arc};

use async_trait::async_trait;

use crate::{
    machine::{build_machine_commitment, constants, MachineCommitment},
    merkle::{Digest, MerkleBuilder},
};

use super::MachineRPC;

#[async_trait]
pub trait MachineCommitmentBuilder {
    async fn build_commitment(
        &mut self,
        base_cycle: u64,
        level: u64,
    ) -> Result<MachineCommitment, Box<dyn Error>>;
}

pub struct CachingMachineCommitmentBuilder {
    machine: MachineRPC,
    commitments: HashMap<u64, HashMap<u64, MachineCommitment>>,
}

impl CachingMachineCommitmentBuilder {
    pub fn new(machine: MachineRPC) -> Self {
        CachingMachineCommitmentBuilder {
            machine,
            commitments: HashMap::new(),
        }
    }
}

#[async_trait]
impl MachineCommitmentBuilder for CachingMachineCommitmentBuilder {
    async fn build_commitment(
        &mut self,
        base_cycle: u64,
        level: u64,
    ) -> Result<MachineCommitment, Box<dyn Error>> {
        assert!(level <= constants::LEVELS);

        if let std::collections::hash_map::Entry::Vacant(e) = self.commitments.entry(level) {
            e.insert(HashMap::new());
        } else if self.commitments[&level].contains_key(&base_cycle) {
            return Ok(self.commitments[&level][&base_cycle].clone());
        }

        let l = constants::LEVELS - level + 1;
        let log2_stride = constants::LOG2_STEP[l as usize];
        let log2_stride_count = constants::HEIGHTS[l as usize];
        let commitment = build_machine_commitment(
            self.machine.clone(),
            base_cycle,
            log2_stride,
            log2_stride_count,
        )
        .await?;

        self.commitments
            .entry(level)
            .or_default()
            .insert(base_cycle, commitment.clone());

        Ok(commitment)
    }
}

pub struct FakeMachineCommitmentBuilder {
    initial_hash: Digest,
    second_state: Option<Digest>,
}

impl FakeMachineCommitmentBuilder {
    pub fn new(initial_hash: Digest, second_state: Option<Digest>) -> Self {
        FakeMachineCommitmentBuilder {
            initial_hash,
            second_state,
        }
    }
}

#[async_trait]
impl MachineCommitmentBuilder for FakeMachineCommitmentBuilder {
    async fn build_commitment(
        &mut self,
        _base_cycle: u64,
        level: u64,
    ) -> Result<MachineCommitment, Box<dyn Error>> {
        let mut merkle_builder = MerkleBuilder::default();
        let level = constants::LEVELS - level + 1;
        if constants::LOG2_STEP[level as usize] == 0 && self.second_state.is_some() {
            merkle_builder.add(self.second_state.unwrap());
            merkle_builder.add_with_repetition(
                Digest::zeroed(),
                (1 << constants::HEIGHTS[level as usize]) - 1,
            );
        } else {
            merkle_builder.add_with_repetition(Digest::zeroed(), 1 << constants::HEIGHTS[level as usize]);
        }

        let merkle = merkle_builder.build();

        Ok(MachineCommitment {
            implicit_hash: self.initial_hash,
            merkle: Arc::new(merkle),
        })
    }
}
