//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use crate::machine::{build_machine_commitment, constants, MachineCommitment, MachineFactory};
use std::{
    collections::{hash_map::Entry, HashMap},
    error::Error,
};

pub struct CachingMachineCommitmentBuilder {
    machine_factory: MachineFactory,
    machine_path: String,
    commitments: HashMap<u64, HashMap<u64, MachineCommitment>>,
}

impl CachingMachineCommitmentBuilder {
    pub fn new(machine_factory: MachineFactory, machine_path: String) -> Self {
        CachingMachineCommitmentBuilder {
            machine_factory,
            machine_path,
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

        let l = constants::LEVELS - level;
        let log2_stride = constants::LOG2_STEP[l as usize];
        let log2_stride_count = constants::HEIGHTS[l as usize];
        let mut machine = self
            .machine_factory
            .create_machine(&self.machine_path)
            .await?;
        let commitment =
            build_machine_commitment(&mut machine, base_cycle, log2_stride, log2_stride_count)
                .await?;

        self.commitments
            .entry(level)
            .or_default()
            .insert(base_cycle, commitment.clone());

        Ok(commitment)
    }
}
