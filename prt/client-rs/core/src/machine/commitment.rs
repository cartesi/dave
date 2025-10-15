//! This module defines a struct [MachineCommitment] that is used to represent a `computation hash`
//! described on the paper https://arxiv.org/pdf/2212.12439.pdf.

use alloy::primitives::U256;
use log::{info, trace};
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Instant;

use crate::{
    db::dispute_state_access::{DisputeStateAccess, Leaf},
    machine::error::Result,
    machine::{MachineInstance, constants},
};
use cartesi_dave_arithmetic::max_uint;
use cartesi_dave_merkle::{Digest, MerkleBuilder, MerkleTree};

/// The [MachineCommitment] struct represents a `computation hash`, that is a [MerkleTree] of a set
/// of steps of the Cartesi Machine.
#[derive(Clone, Debug)]
pub struct MachineCommitment {
    pub implicit_hash: Digest,
    pub merkle: Arc<MerkleTree>,
}

/// Builds a [MachineCommitment] from a [MachineInstance] and a base cycle and leafs.
pub fn build_machine_commitment_from_leafs<L>(
    leafs: Vec<(L, u64)>,
    initial_state: Digest,
) -> Result<MachineCommitment>
where
    L: Into<Arc<MerkleTree>>,
{
    let mut builder = MerkleBuilder::default();
    for leaf in leafs {
        builder.append_repeated(leaf.0, leaf.1);
    }
    let tree = builder.build();

    Ok(MachineCommitment {
        implicit_hash: initial_state,
        merkle: tree,
    })
}

/// Builds a [MachineCommitment] from a [MachineInstance] and a base cycle.
pub fn build_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: U256,
    level: u64,
    log2_stride: u64,
    log2_stride_count: u64,
    db: &DisputeStateAccess,
) -> Result<Vec<(Arc<MerkleTree>, u64)>> {
    info!(
        "Begin building commitment for level {level}: start cycle {base_cycle}, log2_stride {log2_stride} and log2_stride_count {log2_stride_count}"
    );

    // If machine is at yielded awaiting input, we unyield it.
    // This puts the machine in an in-between state transion;
    // its state hash is now meaningless until we run an instruction.
    if machine.cycle == 0 && machine.ucycle == 0 {
        assert!(machine.is_yielded()?);
        machine.feed_next_input(db)?;
    }

    let start = Instant::now();

    if log2_stride >= constants::LOG2_UARCH_SPAN_TO_BARCH {
        assert!(
            log2_stride + log2_stride_count
                <= constants::LOG2_INPUT_SPAN_TO_EPOCH
                    + constants::LOG2_BARCH_SPAN_TO_INPUT
                    + constants::LOG2_UARCH_SPAN_TO_BARCH
        );
        build_big_machine_commitment(
            machine,
            level,
            base_cycle,
            log2_stride,
            log2_stride_count,
            db,
        )?;
    } else {
        assert!(log2_stride == 0);
        build_small_machine_commitment(machine, level, base_cycle, log2_stride_count, db)?;
    }

    info!(
        "Finished building for level {level} (start cycle {base_cycle}, log2_stride {log2_stride} and log2_stride_count {log2_stride_count}) in {} seconds",
        start.elapsed().as_secs()
    );

    Ok(db.leafs(level, log2_stride, log2_stride_count, base_cycle)?)
}

/// Builds a [MachineCommitment] Hash for the Cartesi Machine using the big machine model.
fn build_big_machine_commitment(
    machine: &mut MachineInstance,
    level: u64,
    base_cycle: U256,
    log2_stride: u64,
    log2_stride_count: u64,
    db: &DisputeStateAccess,
) -> Result<()> {
    let mut leafs = Vec::new();
    let instruction_count = 1 << log2_stride_count;
    let stride = 1 << (log2_stride - constants::LOG2_UARCH_SPAN_TO_BARCH);

    for instruction in 0..instruction_count {
        print_flush_same_line(&format!(
            "building big machine commitment ({}/{})...",
            instruction, instruction_count
        ));

        let cycle = machine.cycle + stride;
        let state = machine.run(cycle)?;

        if !(state.halted | state.yielded) {
            leafs.push(Leaf {
                hash: state.root_hash.into(),
                repetitions: 1,
            });
        } else {
            trace!("big advance halted/yielded",);
            leafs.push(Leaf {
                hash: state.root_hash.into(),
                repetitions: instruction_count - instruction,
            });
            break;
        }
    }
    finish_print_flush_same_line();

    db.insert_leafs(level, base_cycle, leafs.iter())?;

    Ok(())
}

fn build_small_machine_commitment(
    machine: &mut MachineInstance,
    level: u64,
    base_cycle: U256,
    log2_stride_count: u64,
    db: &DisputeStateAccess,
) -> Result<()> {
    let span_count = max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN_TO_BARCH);

    let mut span = 0;
    while span <= span_count {
        print_flush_same_line(&format!(
            "building small machine commitment ({}/{})...",
            span, span_count
        ));

        run_uarch_span(machine, base_cycle, level, db)?;
        let machine_state = machine.state()?;
        span += 1;

        // if the machine is yielded, we need to run another uarch span
        if machine_state.halted || machine_state.yielded {
            trace!("uarch span machine halted/yielded");
            run_uarch_span(machine, base_cycle, level, db)?;
            break;
        }
    }
    finish_print_flush_same_line();

    Ok(())
}

fn run_uarch_span(
    machine: &mut MachineInstance,
    base_cycle: U256,
    level: u64,
    db: &DisputeStateAccess,
) -> Result<()> {
    let (_, ucycle) = machine.position()?;
    assert!(ucycle == 0);

    let mut machine_state;
    let mut leafs = Vec::new();
    let mut i = 0;

    loop {
        machine_state = machine.increment_uarch()?;
        leafs.push(Leaf {
            hash: machine_state.root_hash.into(),
            repetitions: 1,
        });

        i += 1;
        if machine_state.uhalted {
            trace!("uarch halted");
            break;
        }
    }

    // Add padding leaf to complete the span
    if i < constants::UARCH_SPAN_TO_BARCH {
        leafs.push(Leaf {
            hash: machine_state.root_hash.into(),
            repetitions: constants::UARCH_SPAN_TO_BARCH - i,
        });
    }

    trace!("state before reset {}", machine_state.root_hash);
    machine_state = machine.ureset()?;
    trace!("state after reset {}", machine_state.root_hash);

    if machine.is_yielded()? {
        machine.revert_if_needed()?;
    }
    leafs.push(Leaf {
        hash: machine.root_hash()?.into(),
        repetitions: 1,
    });
    db.insert_leafs(level, base_cycle, leafs.iter())?;

    Ok(())
}

fn print_flush_same_line(args: &str) {
    print!("\r{}", args);
    // Flush the output to ensure it appears immediately
    io::stdout().flush().unwrap();
}

fn finish_print_flush_same_line() {
    println!();
    // Flush the output to ensure it appears immediately
    io::stdout().flush().unwrap();
}
