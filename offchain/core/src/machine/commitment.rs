//! This module defines a struct [MachineCommitment] that is used to represent a `computation hash`
//! described on the paper https://arxiv.org/pdf/2212.12439.pdf.

use std::{error::Error, ops::ControlFlow, sync::Arc};

use tokio::sync::Mutex;

pub type MachineRPC = Arc<Mutex<MachineRpc>>;

use crate::{
    machine::{constants, MachineRpc},
    merkle::{Digest, MerkleBuilder, MerkleTree, UInt},
    utils::arithmetic,
};

/// The [MachineCommitment] struct represents a `computation hash`, that is a [MerkleTree] of a set
/// of steps of the Cartesi Machine.
#[derive(Clone, Debug)]
pub struct MachineCommitment {
    pub implicit_hash: Digest,
    pub merkle: Arc<MerkleTree>,
}

/// Builds a [MachineCommitment] from a [MachineRpc] and a base cycle.
pub async fn build_machine_commitment(
    machine: MachineRPC,
    base_cycle: u64,
    log2_stride: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment, Box<dyn Error>> {
    if log2_stride >= constants::LOG2_UARCH_SPAN {
        assert!(
            log2_stride + log2_stride_count
                <= constants::LOG2_EMULATOR_SPAN + constants::LOG2_UARCH_SPAN
        );
        build_big_machine_commitment(machine, base_cycle, log2_stride, log2_stride_count).await
    } else {
        build_small_machine_commitment(machine, base_cycle, log2_stride_count).await
    }
}

/// Builds a [MachineCommitment] Hash for the Cartesi Machine using the big machine model.
pub async fn build_big_machine_commitment(
    machine: Arc<Mutex<MachineRpc>>,
    base_cycle: u64,
    log2_stride: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment, Box<dyn Error>> {
    let machine_lock = machine.clone();
    let mut machine = machine_lock.lock().await;

    machine.run(base_cycle).await?;
    let initial_state = machine.machine_state().await?;

    let mut builder = MerkleBuilder::default();
    let instruction_count = arithmetic::max_uint(log2_stride_count);

    for instruction in 0..instruction_count {
        let control_flow = advance_instruction(
            instruction,
            log2_stride,
            &mut machine,
            base_cycle,
            &mut builder,
            instruction_count,
        )
        .await?;
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

async fn advance_instruction(
    instruction: u64,
    log2_stride: u64,
    machine: &mut MachineRpc,
    base_cycle: u64,
    builder: &mut MerkleBuilder,
    instruction_count: u64,
) -> Result<ControlFlow<()>, Box<dyn Error>> {
    let cycle = (instruction + 1) << (log2_stride - constants::LOG2_UARCH_SPAN);
    machine.run(base_cycle + cycle).await?;
    let state = machine.machine_state().await?;
    let control_flow = if state.halted {
        builder.add(state.root_hash);
        ControlFlow::Continue(())
    } else {
        builder.add_with_repetition(
            state.root_hash,
            UInt::from(instruction_count - instruction + 1),
        );
        ControlFlow::Break(())
    };
    Ok(control_flow)
}

pub async fn build_small_machine_commitment(
    machine: MachineRPC,
    base_cycle: u64,
    log2_stride_count: u64,
) -> Result<MachineCommitment, Box<dyn Error>> {
    let machine_lock = machine.clone();
    let mut machine = machine_lock.lock().await;

    machine.run(base_cycle).await?;
    let initial_state = machine.machine_state().await?;

    let mut builder = MerkleBuilder::default();
    let instruction_count = arithmetic::max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN);
    let mut instructions = 0;
    loop {
        if !instructions <= instruction_count {
            break;
        }

        builder.add_with_repetition(run_uarch_span(&mut machine).await?.root_hash(), 1);
        instructions += 1;

        let state = machine.machine_state().await?;
        if state.halted {
            builder.add_with_repetition(
                run_uarch_span(&mut machine).await?.root_hash(),
                UInt::from(instruction_count - instructions + 1),
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

async fn run_uarch_span(
    machine: &mut MachineRpc,
) -> Result<MerkleTree, Box<dyn Error>> {
    let (ucycle, _) = machine.position();
    assert!(ucycle == 0);

    machine.increment_uarch().await?;

    let mut builder = MerkleBuilder::default();
    let mut i = 0;

    let mut state = loop {
        let mut state = machine.machine_state().await?;
        builder.add_with_repetition(state.root_hash, 1);

        machine.increment_uarch().await?;
        i += 1;

        state = machine.machine_state().await?;
        if state.uhalted {
            break state;
        }
    };

    builder.add_with_repetition(state.root_hash, UInt::from(constants::UARCH_SPAN - i));

    machine.ureset().await?;
    state = machine.machine_state().await?;
    builder.add_with_repetition(state.root_hash, 1);

    Ok(builder.build())
}
