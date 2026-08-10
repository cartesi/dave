// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The prototype commitment builder: the differential oracle the engine
//! machine tests compare against. It
//! predates the quartet cache and computes commitments by driving the
//! machine leaf by leaf; nothing here persists - leaf runs are cached
//! in memory per builder, purely to mirror the old behavior.

use super::epoch_data::{EpochData, Leaf};
use super::instance::MachineInstance;
use super::machine_error::Result;
use cartesi_rollups_prt_node::engine::constants;

use alloy::primitives::U256;
use cartesi_rollups_prt_node::arithmetic::max_uint;
use cartesi_rollups_prt_node::merkle::{Digest, MerkleBuilder, MerkleTree};
use log::{info, trace};
use std::collections::HashMap;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The oracle's leaf-run cache, keyed by (level, base_cycle); appended
/// run by run, read back whole.
#[derive(Debug, Default)]
pub struct LeafStore {
    leafs: Mutex<HashMap<(u64, U256), Vec<Leaf>>>,
}

impl LeafStore {
    pub fn insert_leafs<'a>(
        &self,
        level: u64,
        base_cycle: U256,
        leafs: impl Iterator<Item = &'a Leaf>,
    ) {
        let mut map = self.leafs.lock().unwrap();
        map.entry((level, base_cycle))
            .or_default()
            .extend(leafs.cloned());
    }

    pub fn leafs(
        &self,
        level: u64,
        log2_stride: u64,
        log2_stride_count: u64,
        base_cycle: U256,
    ) -> Vec<(Arc<MerkleTree>, u64)> {
        let leafs: Vec<Leaf> = self
            .leafs
            .lock()
            .unwrap()
            .get(&(level, base_cycle))
            .cloned()
            .unwrap_or_default();

        if log2_stride == 0 && !leafs.is_empty() {
            leafs_with_uarch(leafs, log2_stride_count)
        } else {
            leafs
                .iter()
                .map(|leaf| (digest_tree(&leaf.hash), leaf.repetitions))
                .collect()
        }
    }
}

fn digest_tree(hash: &[u8; 32]) -> Arc<MerkleTree> {
    Digest::from_digest(hash)
        .expect("leaf hashes are 32 bytes")
        .into()
}

fn leafs_with_uarch(leafs: Vec<Leaf>, log2_stride_count: u64) -> Vec<(Arc<MerkleTree>, u64)> {
    let mut main_tree = Vec::new();
    let span_count = max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN_TO_BARCH) + 1;
    let span_size = constants::UARCH_MASK_TO_BARCH + 1;
    let mut accumulated_repetitions = 0;
    let mut uarch_tree_builder = MerkleBuilder::default();

    for leaf in leafs {
        if accumulated_repetitions == 0 {
            // reset the uarch_tree builder
            uarch_tree_builder = MerkleBuilder::default();
        }

        if accumulated_repetitions < span_size {
            uarch_tree_builder.append_repeated(
                Digest::from_digest(&leaf.hash).expect("leaf hashes are 32 bytes"),
                leaf.repetitions,
            );
            accumulated_repetitions += leaf.repetitions;
        }
        if accumulated_repetitions == span_size {
            // here we build a uarch_tree and add it to the main tree
            main_tree.push((uarch_tree_builder.build(), 1));
            // reset the accumulated repetitions
            accumulated_repetitions = 0;
        }
    }

    assert!(!main_tree.is_empty());
    let main_tree_len = main_tree.len() as u64;
    if main_tree_len < span_count {
        main_tree.push((uarch_tree_builder.build(), span_count - main_tree_len));
    }

    main_tree
}

/// A `computation hash`: a merkle tree over a set of machine steps.
#[derive(Clone, Debug)]
pub struct MachineCommitment {
    #[allow(dead_code)]
    pub implicit_hash: Digest,
    pub merkle: Arc<MerkleTree>,
}

pub struct MachineCommitmentBuilder {
    machine_path: String,
    leafs: LeafStore,
}

impl MachineCommitmentBuilder {
    pub fn new(machine_path: String) -> Self {
        MachineCommitmentBuilder {
            machine_path,
            leafs: LeafStore::default(),
        }
    }

    pub fn build_commitment(
        &mut self,
        base_cycle: U256,
        level: u64,
        log2_stride: u64,
        log2_stride_count: u64,
        db: &EpochData,
    ) -> Result<MachineCommitment> {
        let mut machine =
            MachineInstance::new_rollups_advanced_until(&self.machine_path, base_cycle, db)?;
        let initial_state = machine.root_hash()?;

        trace!("initial state for commitment: {}", initial_state);
        let commitment = {
            let mut leafs = self
                .leafs
                .leafs(level, log2_stride, log2_stride_count, base_cycle);
            // leafs are cached, use them to calculate merkle
            if leafs.is_empty() {
                // leafs are not cached, build merkle by running the machine
                leafs = build_machine_commitment(
                    &mut machine,
                    base_cycle,
                    level,
                    log2_stride,
                    log2_stride_count,
                    db,
                    &self.leafs,
                )?;
                assert!(!leafs.is_empty());
            }
            build_machine_commitment_from_leafs(leafs, initial_state)?
        };

        Ok(commitment)
    }
}

/// Builds a [MachineCommitment] from leafs.
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
#[allow(clippy::too_many_arguments)]
pub fn build_machine_commitment(
    machine: &mut MachineInstance,
    base_cycle: U256,
    level: u64,
    log2_stride: u64,
    log2_stride_count: u64,
    db: &EpochData,
    store: &LeafStore,
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
            store,
        )?;
    } else {
        assert!(log2_stride == 0);
        build_small_machine_commitment(machine, level, base_cycle, log2_stride_count, store)?;
    }

    info!(
        "Finished building for level {level} (start cycle {base_cycle}, log2_stride {log2_stride} and log2_stride_count {log2_stride_count}) in {} seconds",
        start.elapsed().as_secs()
    );

    Ok(store.leafs(level, log2_stride, log2_stride_count, base_cycle))
}

/// Builds a [MachineCommitment] Hash for the Cartesi Machine using the big machine model.
fn build_big_machine_commitment(
    machine: &mut MachineInstance,
    level: u64,
    base_cycle: U256,
    log2_stride: u64,
    log2_stride_count: u64,
    store: &LeafStore,
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

    store.insert_leafs(level, base_cycle, leafs.iter());

    Ok(())
}

fn build_small_machine_commitment(
    machine: &mut MachineInstance,
    level: u64,
    base_cycle: U256,
    log2_stride_count: u64,
    store: &LeafStore,
) -> Result<()> {
    let span_count = max_uint(log2_stride_count - constants::LOG2_UARCH_SPAN_TO_BARCH);

    let mut span = 0;
    while span <= span_count {
        print_flush_same_line(&format!(
            "building small machine commitment ({}/{})...",
            span, span_count
        ));

        run_uarch_span(machine, base_cycle, level, store)?;
        let machine_state = machine.state()?;
        span += 1;

        // if the machine is yielded, we need to run another uarch span
        if machine_state.halted || machine_state.yielded {
            trace!("uarch span machine halted/yielded");
            run_uarch_span(machine, base_cycle, level, store)?;
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
    store: &LeafStore,
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
    if i < constants::UARCH_MASK_TO_BARCH {
        leafs.push(Leaf {
            hash: machine_state.root_hash.into(),
            repetitions: constants::UARCH_MASK_TO_BARCH - i,
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
    store.insert_leafs(level, base_cycle, leafs.iter());

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
