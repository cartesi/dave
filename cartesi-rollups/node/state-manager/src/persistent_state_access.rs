// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::{Path, PathBuf};

use crate::{
    CommitmentLeaf, Epoch, Input, InputId, Settlement, StateManager,
    rollups_machine::{self, RollupsMachine},
    sql::*,
    state_manager::Result,
};

use alloy::primitives::U256;
use cartesi_dave_merkle::{Digest, MerkleBuilder};
use rusqlite::Connection;

#[derive(Debug)]
pub struct PersistentStateAccess {
    connection: Connection,
    state_dir: PathBuf,
}

impl PersistentStateAccess {
    pub fn migrate(
        state_dir: &Path,
        initial_machine_path: &Path,
        genesis_block_number: u64,
    ) -> Result<Self> {
        create_empty_state_dir_if_needed(state_dir)?;
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;
        let connection = migrate(&state_dir, initial_machine_path, genesis_block_number)?;

        Ok(Self {
            connection,
            state_dir,
        })
    }

    pub fn new(state_dir: &Path) -> Result<Self> {
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;
        let connection = create_connection(&state_dir)?;

        Ok(Self {
            connection,
            state_dir,
        })
    }

    pub fn db_path(&self) -> PathBuf {
        db_path(&self.state_dir)
    }

    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }
}

impl StateManager for PersistentStateAccess {
    //
    // Consensus Data
    //

    fn epoch(&mut self, epoch_number: u64) -> Result<Option<Epoch>> {
        consensus_data::epoch(&self.connection, epoch_number)
    }

    fn epoch_count(&mut self) -> Result<u64> {
        consensus_data::epoch_count(&self.connection)
    }

    fn last_sealed_epoch(&mut self) -> Result<Option<Epoch>> {
        consensus_data::last_sealed_epoch(&self.connection)
    }

    fn input(&mut self, id: &InputId) -> Result<Option<Input>> {
        consensus_data::input(&self.connection, id)
    }

    fn inputs(&mut self, epoch_number: u64) -> Result<Vec<Vec<u8>>> {
        consensus_data::inputs(&self.connection, epoch_number)
    }

    fn input_count(&mut self, epoch_number: u64) -> Result<u64> {
        consensus_data::input_count(&self.connection, epoch_number)
    }

    fn last_input(&mut self) -> Result<Option<InputId>> {
        consensus_data::last_input(&self.connection)
    }

    fn insert_consensus_data<'a>(
        &mut self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()> {
        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;
        consensus_data::update_last_processed_block(&tx, last_processed_block)?;
        consensus_data::insert_inputs(&tx, inputs)?;
        consensus_data::insert_epochs(&tx, epochs)?;
        tx.commit().map_err(anyhow::Error::from)?;

        Ok(())
    }

    fn latest_processed_block(&mut self) -> Result<u64> {
        consensus_data::last_processed_block(&self.connection)
    }

    //
    // Rollup Data
    //
    fn advance_accepted(
        &mut self,
        machine: &mut RollupsMachine,
        leafs: &[CommitmentLeaf],
    ) -> Result<()> {
        assert!(!leafs.is_empty());
        let epoch = machine.epoch();
        let next_input_index = machine.next_input_index_in_epoch();
        let processed_input_index = next_input_index - 1;

        rollup_data::insert_state_hashes_for_input(
            &self.connection,
            epoch,
            processed_input_index,
            leafs,
        )?;

        let (dest_dir, state_hash) = {
            let snapshots_path = snapshots_path(&self.state_dir);
            machine
                .store_if_needed(&snapshots_path)
                .map_err(anyhow::Error::from)?
        };

        rollup_data::insert_snapshot(
            &self.connection,
            epoch,
            next_input_index,
            &state_hash,
            &dest_dir,
        )?;
        rollup_data::gc_previous_advances(&self.connection, epoch, next_input_index)?;

        Ok(())
    }

    fn advance_reverted(
        &mut self,
        machine: &mut RollupsMachine,
        leafs: &[CommitmentLeaf],
    ) -> Result<()> {
        assert!(!leafs.is_empty());
        let epoch = machine.epoch();
        let next_input_index = machine.next_input_index_in_epoch();
        let processed_input_index = next_input_index - 1;

        rollup_data::insert_state_hashes_for_input(
            &self.connection,
            epoch,
            processed_input_index,
            leafs,
        )?;

        let (snapshot_path, snapshot_epoch, snapshot_input) =
            rollup_data::latest_snapshot_path(&self.connection)?;

        assert_eq!(snapshot_epoch, epoch);
        assert_eq!(snapshot_input, processed_input_index);

        // load rollups machine from previous successful (ACCEPT) snapshot
        let mut reverted_machine = RollupsMachine::new(&snapshot_path, epoch, next_input_index)?;

        rollup_data::insert_snapshot(
            &self.connection,
            epoch,
            next_input_index,
            &reverted_machine.state_hash()?,
            &snapshot_path,
        )?;
        rollup_data::gc_previous_advances(&self.connection, epoch, next_input_index)?;

        // Update the passed machine to match the reverted state
        *machine = reverted_machine;
        Ok(())
    }

    fn next_input_id(&mut self) -> Result<InputId> {
        rollup_data::next_input_to_be_processed(&self.connection)
    }

    fn epoch_state_hashes(&mut self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
        let mut leafs = rollup_data::get_all_commitments(&self.connection, epoch_number)?;

        let total_reps = leafs.iter().fold(0, |acc, leaf| acc + leaf.repetitions);
        if let Some(last) = leafs.last_mut() {
            last.repetitions += rollups_machine::STRIDE_COUNT_IN_EPOCH - total_reps
        }

        Ok(leafs)
    }

    fn settlement_info(&mut self, epoch_number: u64) -> Result<Option<Settlement>> {
        rollup_data::settlement_info(&self.connection, epoch_number)
    }

    fn roll_epoch(&mut self) -> Result<()> {
        let mut machine = self.latest_snapshot()?;
        let previous_epoch_number = machine.epoch();

        let settlement = {
            let leafs = rollup_data::get_all_commitments(&self.connection, previous_epoch_number)?;

            let computation_hash = if !leafs.is_empty() {
                build_commitment_from_hashes(&leafs)
            } else {
                assert_eq!(machine.next_input_index_in_epoch(), 0);
                build_commitment_from_hashes(&[CommitmentLeaf {
                    hash: machine.state_hash()?,
                    repetitions: 1,
                }])
            };

            let (output_merkle, output_proof) = machine.outputs_proof()?;

            Settlement {
                computation_hash,
                output_merkle,
                output_proof,
            }
        };

        machine.finish_epoch();

        let new_epoch_number = machine.epoch();
        create_epoch_dir(&self.state_dir, new_epoch_number)?;

        let (dest_dir, state_hash) = {
            let snapshots_path = snapshots_path(&self.state_dir);
            machine
                .store_if_needed(&snapshots_path)
                .map_err(anyhow::Error::from)?
        };

        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;
        rollup_data::insert_snapshot(&tx, new_epoch_number, 0, &state_hash, &dest_dir)?;
        rollup_data::insert_settlement_info(&tx, &settlement, previous_epoch_number)?;
        tx.commit().map_err(anyhow::Error::from)?;

        if previous_epoch_number >= 1 {
            rollup_data::gc_old_epochs(&self.connection, previous_epoch_number - 1)?;
        }

        Ok(())
    }

    fn snapshot(&mut self, epoch_number: u64, input_number: u64) -> Result<Option<RollupsMachine>> {
        let ret = if let Some(path) =
            rollup_data::snapshot_path_for_epoch(&self.connection, epoch_number, input_number)?
        {
            Some(RollupsMachine::new(&path, epoch_number, 0)?)
        } else {
            None
        };

        Ok(ret)
    }

    fn latest_snapshot(&mut self) -> Result<crate::rollups_machine::RollupsMachine> {
        let (path, epoch_number, input_number) =
            rollup_data::latest_snapshot_path(&self.connection)?;
        Ok(RollupsMachine::new(&path, epoch_number, input_number)?)
    }

    fn snapshot_dir(&mut self, epoch_number: u64, input_number: u64) -> Result<Option<PathBuf>> {
        rollup_data::snapshot_path_for_epoch(&self.connection, epoch_number, input_number)
    }

    //
    // Directory
    //

    fn epoch_directory(&mut self, epoch_number: u64) -> Result<PathBuf> {
        create_epoch_dir(&self.state_dir, epoch_number)
    }
}

fn build_commitment_from_hashes(state_hashes: &[CommitmentLeaf]) -> Digest {
    let mut builder = MerkleBuilder::default();

    assert!(!state_hashes.is_empty());
    let (last, hashes) = state_hashes.split_last().unwrap();

    for state_hash in hashes {
        builder.append_repeated(Digest::new(state_hash.hash), state_hash.repetitions);
    }

    // If count is zero, this means tree is full, but we still have the last leaf to add.
    assert_ne!(builder.count(), Some(U256::ZERO));

    // Complete tree
    builder.append_repeated(
        Digest::new(last.hash),
        U256::from(rollups_machine::STRIDE_COUNT_IN_EPOCH) - builder.count().unwrap_or(U256::ZERO),
    );

    let tree = builder.build();
    tree.root_hash()
}

#[cfg(test)]
mod tests {
    use alloy::primitives::Address;
    use cartesi_machine::{
        Machine,
        config::{
            machine::{MachineConfig, RAMConfig},
            runtime::RuntimeConfig,
        },
    };

    use super::*;

    fn setup() -> (tempfile::TempDir, PersistentStateAccess) {
        let state_dir_ = tempfile::tempdir().unwrap();
        let state_dir = state_dir_.path();

        let machine_path = state_dir.join("_my_machine_image");
        let mut machine = Machine::create(
            &MachineConfig::new_with_ram(RAMConfig {
                length: 134217728,
                backing_store: cartesi_machine::config::machine::BackingStoreConfig {
                    data_filename: "../../../test/programs/linux.bin".into(),
                    ..Default::default()
                },
            }),
            &RuntimeConfig::default(),
        )
        .unwrap();
        machine.store(&machine_path).unwrap();

        let acc = PersistentStateAccess::migrate(state_dir, &machine_path, 0).unwrap();

        (state_dir_, acc)
    }

    #[test]
    fn test_state_access() -> super::Result<()> {
        let input_0_bytes = b"hello";
        let input_1_bytes = b"world";

        let (_handle, mut access) = setup();

        let mut initial_snapshot = access.latest_snapshot().unwrap();
        assert_eq!(initial_snapshot.epoch(), 0);

        access.insert_consensus_data(
            20,
            [
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 0,
                    },
                    data: input_0_bytes.to_vec(),
                },
                &Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 1,
                    },
                    data: input_1_bytes.to_vec(),
                },
            ]
            .into_iter(),
            [&Epoch {
                epoch_number: 0,
                input_index_boundary: 12,
                root_tournament: Address::ZERO,
                block_created_number: 0,
            }]
            .into_iter(),
        )?;

        assert_eq!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                })?
                .map(|x| x.data),
            Some(input_0_bytes.to_vec()),
            "input 0 bytes should match"
        );
        assert_eq!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 1
                })?
                .map(|x| x.data),
            Some(input_1_bytes.to_vec()),
            "input 1 bytes should match"
        );
        assert!(
            access
                .input(&InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 2
                })?
                .is_none(),
            "input 2 shouldn't exist"
        );

        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 1,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "duplicate input index should fail"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 3,
                        },
                        data: input_0_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_err(),
            "input index should be sequential"
        );
        assert!(
            access
                .insert_consensus_data(
                    21,
                    [&Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 2,
                        },
                        data: input_1_bytes.to_vec(),
                    }]
                    .into_iter(),
                    [].into_iter(),
                )
                .is_ok(),
            "add sequential input should succeed"
        );

        assert_eq!(
            access.latest_processed_block()?,
            21,
            "latest block should match"
        );

        assert!(
            access.epoch_state_hashes(0)?.is_empty(),
            "machine state hashes shouldn't exist"
        );

        let commitment_leaf_1 = CommitmentLeaf {
            hash: [1; 32],
            repetitions: 1,
        };
        let commitment_leaf_2 = CommitmentLeaf {
            hash: [2; 32],
            repetitions: 5,
        };

        initial_snapshot.increment_input();
        access.advance_accepted(
            &mut initial_snapshot,
            std::slice::from_ref(&commitment_leaf_1),
        )?;

        assert_eq!(
            access.epoch_state_hashes(0)?[0],
            CommitmentLeaf {
                hash: [1; 32],
                repetitions: rollups_machine::STRIDE_COUNT_IN_EPOCH,
            },
            "machine state 1 data should match"
        );
        assert_eq!(
            access.epoch_state_hashes(0)?.len(),
            1,
            "machine state 1 count shouldn't exist"
        );

        initial_snapshot.increment_input();
        access.advance_reverted(
            &mut initial_snapshot,
            std::slice::from_ref(&commitment_leaf_2),
        )?;

        assert_eq!(
            access.epoch_state_hashes(0)?.len(),
            2,
            "machine state 2 count shouldn't exist"
        );

        assert!(
            access.settlement_info(1)?.is_none(),
            "computation_hash shouldn't exist"
        );

        let (output_merkle, output_proof) = initial_snapshot.outputs_proof()?;
        access.roll_epoch()?;
        assert_eq!(access.latest_snapshot()?.epoch(), 1);

        assert_eq!(
            access.settlement_info(0)?.unwrap(),
            Settlement {
                computation_hash: build_commitment_from_hashes(&[
                    commitment_leaf_1.clone(),
                    commitment_leaf_2.clone()
                ]),
                output_merkle,
                output_proof
            },
            "settlement info of epoch 0 should match"
        );

        Ok(())
    }
}
