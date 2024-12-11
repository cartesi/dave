//! This module defines a struct [MachineCommitment] that is used to represent a `computation hash`
//! described on the paper https://arxiv.org/pdf/2212.12439.pdf.

use anyhow::Result;
use log::trace;
use std::io::{self, Write};
use std::{ops::ControlFlow, sync::Arc};

use crate::{
    db::compute_state_access::{ComputeStateAccess, Leaf},
    machine::{constants, MachineInstance, MachineState},
};
use cartesi_dave_arithmetic as arithmetic;
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
    base_cycle: u64,
    level: u64,
    log2_stride: u64,
    log2_stride_count: u64,
    initial_state: Digest,
    db: &ComputeStateAccess,
) -> Result<MachineCommitment> {
    if log2_stride >= constants::LOG2_UARCH_SPAN {
        assert!(
            log2_stride + log2_stride_count
                <= constants::LOG2_INPUT_SPAN
                    + constants::LOG2_EMULATOR_SPAN
                    + constants::LOG2_UARCH_SPAN
        );
        build_big_machine_commitment(
            machine,
            base_cycle,
            level,
            log2_stride,
            log2_stride_count,
            initial_state,
            db,
        )
    } else {
        assert!(log2_stride == 0);
        build_small_machine_commitment(
            machine,
            base_cycle,
            level,
            log2_stride_count,
            initial_state,
            db,
        )
    }
}

/// Builds a [MachineCommitment] Hash for the Cartesi Machine using the big machine model.
pub fn build_big_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: u64,
    level: u64,
    log2_stride: u64,
    log2_stride_count: u64,
    initial_state: Digest,
    db: &ComputeStateAccess,
) -> Result<MachineCommitment> {
    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let instruction_count = arithmetic::max_uint(log2_stride_count);

    for instruction in 0..=instruction_count {
        print_flush_same_line(&format!(
            "building big machine commitment ({}/{})...",
            instruction, instruction_count
        ));

        let control_flow = advance_instruction(
            instruction,
            log2_stride,
            machine,
            base_cycle,
            &mut builder,
            instruction_count,
            &mut leafs,
        )?;
        if let ControlFlow::Break(_) = control_flow {
            break;
        }
    }
    finish_print_flush_same_line();

    let merkle = builder.build();
    let compute_leafs: Vec<Leaf> = leafs.iter().map(|l| Leaf(l.0.data(), l.1)).collect();
    db.insert_compute_leafs(level, base_cycle, compute_leafs.iter())?;

    Ok(MachineCommitment {
        implicit_hash: initial_state,
        merkle,
    })
}

fn advance_instruction(
    instruction: u64,
    log2_stride: u64,
    machine: &mut MachineInstance,
    base_cycle: u64,
    builder: &mut MerkleBuilder,
    instruction_count: u64,
    leafs: &mut Vec<(Digest, u64)>,
) -> Result<ControlFlow<()>> {
    let cycle = (instruction + 1) << (log2_stride - constants::LOG2_UARCH_SPAN);
    let state = machine.run(base_cycle + cycle)?;
    let control_flow = if state.halted | state.yielded {
        leafs.push((state.root_hash, instruction_count - instruction + 1));
        trace!("big advance halted/yielded",);
        builder.append_repeated(state.root_hash, instruction_count - instruction + 1);
        ControlFlow::Break(())
    } else {
        leafs.push((state.root_hash, 1));
        builder.append(state.root_hash);
        ControlFlow::Continue(())
    };
    Ok(control_flow)
}

pub fn build_small_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: u64,
    level: u64,
    log2_stride_count: u64,
    initial_state: Digest,
    db: &ComputeStateAccess,
) -> Result<MachineCommitment> {
    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let mut uarch_span_and_leafs = Vec::new();
    let instruction_count = arithmetic::max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN);
    let mut instruction = 0;
    loop {
        if instruction > instruction_count {
            break;
        }

        print_flush_same_line(&format!(
            "building small machine commitment ({}/{})...",
            instruction, instruction_count
        ));

        let (mut uarch_tree, machine_state, mut uarch_leafs) = run_uarch_span(machine)?;
        uarch_span_and_leafs.push((uarch_tree.root_hash(), uarch_leafs.clone()));
        leafs.push((uarch_tree.root_hash(), 1));
        builder.append(uarch_tree.clone());
        instruction += 1;

        if machine_state.halted | machine_state.yielded {
            (uarch_tree, _, uarch_leafs) = run_uarch_span(machine)?;
            trace!(
                "uarch span machine halted/yielded {} {}",
                uarch_tree.root_hash(),
                instruction
            );
            uarch_span_and_leafs.push((uarch_tree.root_hash(), uarch_leafs));
            leafs.push((uarch_tree.root_hash(), instruction_count - instruction + 1));
            builder.append_repeated(uarch_tree, instruction_count - instruction + 1);
            break;
        }
    }
    finish_print_flush_same_line();

    let merkle = builder.build();
    let compute_leafs: Vec<Leaf> = leafs.iter().map(|l| Leaf(l.0.data(), l.1)).collect();
    db.insert_compute_leafs(level, base_cycle, compute_leafs.iter())?;
    db.insert_compute_trees(uarch_span_and_leafs.iter())?;

    Ok(MachineCommitment {
        implicit_hash: initial_state,
        merkle,
    })
}

fn run_uarch_span(
    machine: &mut MachineInstance,
) -> Result<(Arc<MerkleTree>, MachineState, Vec<Leaf>)> {
    let (_, ucycle, _) = machine.position()?;
    assert!(ucycle == 0);

    let mut machine_state = machine.increment_uarch()?;

    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let mut i = 0;

    loop {
        leafs.push((machine_state.root_hash, 1));
        builder.append(machine_state.root_hash);

        machine_state = machine.increment_uarch()?;
        i += 1;
        if machine_state.uhalted {
            trace!("uarch halted");
            break;
        }
    }

    leafs.push((machine_state.root_hash, constants::UARCH_SPAN - i));
    builder.append_repeated(machine_state.root_hash, constants::UARCH_SPAN - i);

    trace!("state before reset {}", machine_state.root_hash);
    machine_state = machine.ureset()?;
    trace!("state after reset {}", machine_state.root_hash);
    leafs.push((machine_state.root_hash, 1));
    builder.append(machine_state.root_hash);
    let uarch_span = builder.build();

    // prepare uarch leafs for later db insertion
    let tree_leafs: Vec<Leaf> = leafs.iter().map(|l| Leaf(l.0.data(), l.1)).collect();

    Ok((uarch_span, machine_state, tree_leafs))
}

fn print_flush_same_line(args: &str) {
    print!("\r{}", args);
    // Flush the output to ensure it appears immediately
    io::stdout().flush().unwrap();
}

fn finish_print_flush_same_line() {
    println!("");
    // Flush the output to ensure it appears immediately
    io::stdout().flush().unwrap();
}
