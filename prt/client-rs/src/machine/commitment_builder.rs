//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use crate::{
    db::compute_state_access::ComputeStateAccess,
    machine::{
        build_machine_commitment, build_machine_commitment_from_leafs, MachineCommitment,
        MachineInstance,
    },
};

use anyhow::Result;
use log::trace;
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
        db: &ComputeStateAccess,
    ) -> Result<MachineCommitment> {
        if let Entry::Vacant(e) = self.commitments.entry(level) {
            e.insert(HashMap::new());
        } else if let Some(commitment) = self.commitments[&level].get(&base_cycle) {
            return Ok(commitment.clone());
        }

        let mut machine = MachineInstance::new(&self.machine_path)?;
        if let Some(snapshot) = db.closest_snapshot(base_cycle)? {
            machine.load_snapshot(&snapshot.1, snapshot.0)?;
        };

        let initial_state = {
            if db.handle_rollups {
                // treat it as rollups
                machine.run_with_inputs(base_cycle, &db)?.root_hash
            } else {
                // treat it as compute
                let root_hash = machine.run(base_cycle)?.root_hash;
                machine.take_snapshot(base_cycle, &db)?;
                root_hash
            }
        };
        trace!("initial state for commitment: {}", initial_state);
        let commitment = {
            let leafs = db.compute_leafs(level, base_cycle)?;
            // leafs are cached in database, use it to calculate merkle
            if leafs.len() > 0 {
                build_machine_commitment_from_leafs(leafs, initial_state)?
            } else {
                // leafs are not cached, build merkle by running the machine
                build_machine_commitment(
                    &mut machine,
                    base_cycle,
                    level,
                    log2_stride,
                    log2_stride_count,
                    initial_state,
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
