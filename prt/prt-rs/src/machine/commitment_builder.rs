//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use crate::machine::{
    build_machine_commitment, build_machine_commitment_from_leafs, MachineCommitment,
    MachineInstance,
};
use cartesi_dave_merkle::Digest;

use anyhow::Result;
use std::collections::{hash_map::Entry, HashMap};

pub struct CachingMachineCommitmentBuilder {
    machine_path: String,
    commitments: HashMap<u64, HashMap<u64, MachineCommitment>>,
}

impl CachingMachineCommitmentBuilder {
    pub fn new(machine_path: String) -> Self {
        CachingMachineCommitmentBuilder {
            machine_path,
            commitments: HashMap::new(),
        }
    }

    pub fn build_commitment(
        &mut self,
        base_cycle: u64,
        level: u64,
        log2_stride: u64,
        log2_stride_count: u64,
        leafs: Vec<(Vec<u8>, u64)>,
    ) -> Result<MachineCommitment> {
        if let Entry::Vacant(e) = self.commitments.entry(level) {
            e.insert(HashMap::new());
        } else if self.commitments[&level].contains_key(&base_cycle) {
            return Ok(self.commitments[&level][&base_cycle].clone());
        }

        let mut machine = MachineInstance::new(&self.machine_path)?;
        let commitment = {
            // leafs are cached in database, use it to calculate merkle
            if leafs.len() > 0 {
                build_machine_commitment_from_leafs(
                    &mut machine,
                    base_cycle,
                    leafs
                        .into_iter()
                        .map(|l| {
                            (
                                Digest::from_digest(&l.0).expect("fail to convert leaf to digest"),
                                l.1,
                            )
                        })
                        .collect(),
                )?
            } else {
                // leafs are not cached, build merkle by running the machine
                build_machine_commitment(&mut machine, base_cycle, log2_stride, log2_stride_count)?
            }
        };

        self.commitments
            .entry(level)
            .or_default()
            .insert(base_cycle, commitment.clone());

        Ok(commitment)
    }
}
