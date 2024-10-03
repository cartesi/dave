//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use crate::{
    db::dispute_state_access::DisputeStateAccess,
    machine::{
        build_machine_commitment, build_machine_commitment_from_leafs, MachineCommitment,
        MachineInstance,
    },
};

use anyhow::Result;
use std::{
    collections::{hash_map::Entry, HashMap},
    path::PathBuf,
};

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
        db: &DisputeStateAccess,
    ) -> Result<MachineCommitment> {
        if let Entry::Vacant(e) = self.commitments.entry(level) {
            e.insert(HashMap::new());
        } else if self.commitments[&level].contains_key(&base_cycle) {
            return Ok(self.commitments[&level][&base_cycle].clone());
        }

        let mut machine = MachineInstance::new(&self.machine_path)?;
        if let Some(snapshot_path) = db.closest_snapshot(base_cycle)? {
            machine.load_snapshot(&PathBuf::from(snapshot_path))?;
        };

        let commitment = {
            let leafs = db.compute_leafs(level, base_cycle)?;
            // leafs are cached in database, use it to calculate merkle
            if leafs.len() > 0 {
                build_machine_commitment_from_leafs(&mut machine, base_cycle, leafs)?
            } else {
                // leafs are not cached, build merkle by running the machine
                build_machine_commitment(
                    &mut machine,
                    base_cycle,
                    level,
                    log2_stride,
                    log2_stride_count,
                    db,
                )?
            }
        };

        self.commitments
            .entry(level)
            .or_default()
            .insert(base_cycle, commitment.clone());

        Ok(commitment)
    }
}
