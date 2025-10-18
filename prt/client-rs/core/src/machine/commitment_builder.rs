//! The builder of machine commitments [MachineCommitmentBuilder] is responsible for building the
//! [MachineCommitment]. It is used by the [Arena] to build the commitments of the tournaments.

use crate::{
    db::dispute_state_access::DisputeStateAccess,
    machine::{
        MachineCommitment, MachineInstance, build_machine_commitment,
        build_machine_commitment_from_leafs, error::Result,
    },
};

use alloy::primitives::U256;
use log::trace;

pub struct MachineCommitmentBuilder {
    machine_path: String,
}

impl MachineCommitmentBuilder {
    pub fn new(machine_path: String) -> Self {
        MachineCommitmentBuilder { machine_path }
    }

    pub fn build_commitment(
        &mut self,
        base_cycle: U256,
        level: u64,
        log2_stride: u64,
        log2_stride_count: u64,
        db: &DisputeStateAccess,
    ) -> Result<MachineCommitment> {
        let mut machine =
            MachineInstance::new_rollups_advanced_until(&self.machine_path, base_cycle, db)?;
        let initial_state = machine.root_hash()?;

        trace!("initial state for commitment: {}", initial_state);
        let commitment = {
            let mut leafs = db.leafs(level, log2_stride, log2_stride_count, base_cycle)?;
            // leafs are cached in database, use it to calculate merkle
            if leafs.is_empty() {
                // leafs are not cached, build merkle by running the machine
                leafs = build_machine_commitment(
                    &mut machine,
                    base_cycle,
                    level,
                    log2_stride,
                    log2_stride_count,
                    db,
                )?;
                assert!(!leafs.is_empty());
            }
            build_machine_commitment_from_leafs(leafs, initial_state)?
        };

        Ok(commitment)
    }
}
