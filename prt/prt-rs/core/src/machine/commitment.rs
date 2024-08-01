//! This module defines a struct [MachineCommitment] that is used to represent a `computation hash`
//! described on the paper https://arxiv.org/pdf/2212.12439.pdf.

use anyhow::Result;
use std::{ops::ControlFlow, sync::Arc};

use crate::machine::{constants, MachineInstance};
use cartesi_dave_arithmetic as arithmetic;
use cartesi_dave_merkle::{Digest, MerkleBuilder, MerkleTree, UInt};

/// The [MachineCommitment] struct represents a `computation hash`, that is a [MerkleTree] of a set
/// of steps of the Cartesi Machine.
#[derive(Clone, Debug)]
pub struct MachineCommitment {
    pub implicit_hash: Digest,
    pub merkle: Arc<MerkleTree>,
}

/// Builds a [MachineCommitment] from a [MachineInstance] and a base cycle.
pub fn build_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: u64,
    log2_stride: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment> {
    if log2_stride >= constants::LOG2_UARCH_SPAN {
        assert!(
            log2_stride + log2_stride_count
                <= constants::LOG2_EMULATOR_SPAN + constants::LOG2_UARCH_SPAN
        );
        build_big_machine_commitment(machine, base_cycle, log2_stride, log2_stride_count)
    } else {
        assert!(log2_stride == 0);
        build_small_machine_commitment(machine, base_cycle, log2_stride_count)
    }
}

/// Builds a [MachineCommitment] Hash for the Cartesi Machine using the big machine model.
pub fn build_big_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: u64,
    log2_stride: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment> {
    machine.run(base_cycle)?;
    let initial_state = machine.machine_state()?;

    let mut builder = MerkleBuilder::default();
    let instruction_count = arithmetic::max_uint(log2_stride_count);

    for instruction in 0..=instruction_count {
        let control_flow = advance_instruction(
            instruction,
            log2_stride,
            machine,
            base_cycle,
            &mut builder,
            instruction_count,
        )?;
        if let ControlFlow::Break(_) = control_flow {
            break;
        }
    }

    let merkle = builder.build();

    Ok(MachineCommitment {
        implicit_hash: initial_state.root_hash,
        merkle: Arc::new(merkle),
    })
}

fn advance_instruction(
    instruction: u64,
    log2_stride: u64,
    machine: &mut MachineInstance,
    base_cycle: u64,
    builder: &mut MerkleBuilder,
    instruction_count: u64,
) -> Result<ControlFlow<()>> {
    let cycle = (instruction + 1) << (log2_stride - constants::LOG2_UARCH_SPAN);
    machine.run(base_cycle + cycle)?;
    let state = machine.machine_state()?;
    let control_flow = if state.halted {
        builder.add_with_repetition(
            state.root_hash,
            UInt::from(instruction_count - instruction + 1),
        );
        ControlFlow::Break(())
    } else {
        builder.add(state.root_hash);
        ControlFlow::Continue(())
    };
    Ok(control_flow)
}

pub fn build_small_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment> {
    machine.run(base_cycle)?;
    let initial_state = machine.machine_state()?;

    let mut builder = MerkleBuilder::default();
    let instruction_count = arithmetic::max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN);
    let mut instruction = 0;
    loop {
        if instruction > instruction_count {
            break;
        }

        builder.add_tree(run_uarch_span(machine)?);
        instruction += 1;

        let state = machine.machine_state()?;
        if state.halted {
            builder.add_tree_with_repetition(
                run_uarch_span(machine)?,
                UInt::from(instruction_count - instruction + 1),
            );
            break;
        }
    }
    let merkle = builder.build();

    Ok(MachineCommitment {
        implicit_hash: initial_state.root_hash,
        merkle: Arc::new(merkle),
    })
}

fn run_uarch_span(machine: &mut MachineInstance) -> Result<MerkleTree> {
    let (_, ucycle) = machine.position();
    assert!(ucycle == 0);

    machine.increment_uarch()?;

    let mut builder = MerkleBuilder::default();
    let mut i = 0;

    let mut state = loop {
        let mut state = machine.machine_state()?;
        builder.add_with_repetition(state.root_hash, 1);

        machine.increment_uarch()?;
        i += 1;

        state = machine.machine_state()?;
        if state.uhalted {
            break state;
        }
    };

    builder.add_with_repetition(state.root_hash, UInt::from(constants::UARCH_SPAN - i));

    machine.ureset()?;
    state = machine.machine_state()?;
    builder.add_with_repetition(state.root_hash, 1);

    Ok(builder.build())
}
