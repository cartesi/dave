//! This module defines a struct [MachineCommitment] that is used to represent a `computation hash`
//! described on the paper https://arxiv.org/pdf/2212.12439.pdf.

use anyhow::Result;
use std::{ops::ControlFlow, sync::Arc};

use crate::{
    db::compute_state_access::{ComputeStateAccess, Leaf},
    machine::{constants, MachineInstance},
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
    snapshot_base_cycle(machine, base_cycle, db)?;

    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let instruction_count = arithmetic::max_uint(log2_stride_count);

    for instruction in 0..=instruction_count {
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
    machine.run(base_cycle + cycle)?;
    let state = machine.machine_state()?;
    let control_flow = if state.halted | state.yielded {
        leafs.push((state.root_hash, instruction_count - instruction + 1));
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
    snapshot_base_cycle(machine, base_cycle, db)?;

    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let instruction_count = arithmetic::max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN);
    let mut instruction = 0;
    loop {
        if instruction > instruction_count {
            break;
        }

        let uarch_span = run_uarch_span(machine, db)?;
        leafs.push((uarch_span.root_hash(), 1));
        builder.append(uarch_span);
        instruction += 1;

        let state = machine.machine_state()?;
        if state.halted {
            let uarch_span = run_uarch_span(machine, db)?;
            leafs.push((uarch_span.root_hash(), instruction_count - instruction + 1));
            builder.append_repeated(uarch_span, instruction_count - instruction + 1);
            break;
        }
    }
    let merkle = builder.build();
    let compute_leafs: Vec<Leaf> = leafs.iter().map(|l| Leaf(l.0.data(), l.1)).collect();
    db.insert_compute_leafs(level, base_cycle, compute_leafs.iter())?;

    Ok(MachineCommitment {
        implicit_hash: initial_state,
        merkle,
    })
}

fn snapshot_base_cycle(
    machine: &mut MachineInstance,
    base_cycle: u64,
    db: &ComputeStateAccess,
) -> Result<()> {
    let mask = arithmetic::max_uint(constants::LOG2_EMULATOR_SPAN);
    if db.handle_rollups && base_cycle & mask == 0 && !machine.machine_state()?.yielded {
        // don't snapshot a machine state that's freshly fed with input without advance
        return Ok(());
    }

    let snapshot_path = db.work_path.join(format!("{}", base_cycle));
    machine.snapshot(&snapshot_path)?;
    Ok(())
}

fn run_uarch_span(
    machine: &mut MachineInstance,
    db: &ComputeStateAccess,
) -> Result<Arc<MerkleTree>> {
    let (_, ucycle) = machine.position();
    assert!(ucycle == 0);

    machine.increment_uarch()?;

    let mut builder = MerkleBuilder::default();
    let mut leafs = Vec::new();
    let mut i = 0;

    let mut state = loop {
        let mut state = machine.machine_state()?;
        leafs.push((state.root_hash, 1));
        builder.append(state.root_hash);

        machine.increment_uarch()?;
        i += 1;

        state = machine.machine_state()?;
        if state.uhalted {
            break state;
        }
    };

    leafs.push((state.root_hash, constants::UARCH_SPAN - i));
    builder.append_repeated(state.root_hash, constants::UARCH_SPAN - i);

    machine.ureset()?;
    state = machine.machine_state()?;
    leafs.push((state.root_hash, 1));
    builder.append(state.root_hash);

    let uarch_span = builder.build();
    let tree_leafs: Vec<Leaf> = leafs.iter().map(|l| Leaf(l.0.data(), l.1)).collect();
    db.insert_compute_tree(uarch_span.root_hash().slice(), tree_leafs.iter())?;

    Ok(uarch_span)
}
