//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use super::MachineRPC;
use crate::machine::{build_machine_commitment, constants, MachineCommitment};
use std::{
    collections::{hash_map::Entry, HashMap},
    error::Error,
};

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

    pub async fn build_commitment(
        &mut self,
        base_cycle: u64,
        level: u64,
    ) -> Result<MachineCommitment, Box<dyn Error>> {
        assert!(level <= constants::LEVELS, "level out of bounds");

        if let Entry::Vacant(e) = self.commitments.entry(level) {
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
