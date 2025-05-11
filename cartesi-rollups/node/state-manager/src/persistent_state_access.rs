// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::{Path, PathBuf};

use crate::{
    CommitmentLeaf, Epoch, Input, InputId, Settlement, StateManager,
    rollups_machine::RollupsMachine, sql::*, state_manager::Result,
};

use cartesi_machine::{Machine, config::runtime::RuntimeConfig};
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
        create_directory_structure(state_dir)?;

        let mut connection = create_connection(state_dir)?;
        migrations::migrate_to_latest(&mut connection).map_err(anyhow::Error::from)?;

        let mut this = Self {
            connection,
            state_dir: state_dir.to_owned(),
        };
        this.set_genesis(genesis_block_number)?;
        this.set_initial_machine(initial_machine_path)?;

        Ok(this)
    }

    pub fn new(state_dir: &Path) -> Result<Self> {
        let connection = create_connection(state_dir)?;

        Ok(Self {
            connection,
            state_dir: state_dir.to_owned(),
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
    // Setup
    //

    fn set_genesis(&mut self, block_number: u64) -> Result<()> {
        let last_processed = self.latest_processed_block()?;

        if block_number > last_processed {
            consensus_data::update_last_processed_block(&self.connection, block_number)?;
        }
        Ok(())
    }

    fn set_initial_machine(&mut self, source_machine_path: &Path) -> Result<()> {
        assert!(
            self.state_dir.is_dir(),
            "`{}` should be a directory",
            self.state_dir.display()
        );
        assert!(
            source_machine_path.is_dir(),
            "machine path `{}` must be an existing directory",
            source_machine_path.display()
        );

        let mut machine = Machine::load(source_machine_path, &RuntimeConfig::default())?;
        let state_hash = machine.root_hash()?;
        let dest_machine_path = machine_path(&self.state_dir, &state_hash);

        if !dest_machine_path.exists() {
            machine.store(&dest_machine_path)?;
            rollup_data::insert_snapshot(&self.connection, 0, &state_hash, &dest_machine_path)?;
        }

        Ok(())
    }

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

    fn latest_processed_block(&mut self) -> Result<u64> {
        consensus_data::last_processed_block(&self.connection)
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

    //
    // Rollup Data
    //

    fn add_machine_state_hashes(
        &mut self,
        epoch_number: u64,
        start_state_hash_index: u64,
        leafs: &[CommitmentLeaf],
    ) -> Result<()> {
        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;

        let (leafs, start_state_hash_index) =
            match rollup_data::get_last_state_hash_index(&tx, epoch_number)? {
                Some(last_idx) if start_state_hash_index <= last_idx => {
                    let overlap_len = std::cmp::min(
                        leafs.len(),
                        (last_idx - start_state_hash_index + 1) as usize,
                    );

                    let (dup, new) = (&leafs[..overlap_len], &leafs[overlap_len..]);
                    rollup_data::validate_dup_commitments(
                        &tx,
                        dup,
                        epoch_number,
                        start_state_hash_index,
                    )?;

                    (new, start_state_hash_index + overlap_len as u64)
                }

                Some(last_idx) => {
                    assert_eq!(start_state_hash_index, last_idx + 1);
                    (leafs, start_state_hash_index)
                }

                None => {
                    assert_eq!(start_state_hash_index, 0);
                    (leafs, start_state_hash_index)
                }
            };

        rollup_data::insert_commitments(&tx, epoch_number, start_state_hash_index, leafs)?;

        tx.commit().map_err(anyhow::Error::from)?;
        Ok(())
    }

    fn machine_state_hash(
        &mut self,
        epoch_number: u64,
        state_hash_index_in_epoch: u64,
    ) -> Result<Option<CommitmentLeaf>> {
        rollup_data::get_commitment_if_exists(
            &self.connection,
            epoch_number,
            state_hash_index_in_epoch,
        )
    }

    // returns all state hashes and their repetitions in acending order of `state_hash_index_in_epoch`
    fn machine_state_hashes(&mut self, epoch_number: u64) -> Result<Vec<CommitmentLeaf>> {
        rollup_data::get_all_commitments(&self.connection, epoch_number)
    }

    fn settlement_info(&mut self, epoch_number: u64) -> Result<Option<Settlement>> {
        rollup_data::settlement_info(&self.connection, epoch_number)
    }

    fn finish_epoch(
        &mut self,
        settlement: &Settlement,
        machine_to_snapshot: &mut crate::rollups_machine::RollupsMachine,
    ) -> Result<()> {
        machine_to_snapshot.finish_epoch();

        let state_hash = machine_to_snapshot.state_hash()?;
        let epoch_number = machine_to_snapshot.epoch();
        create_epoch_dir(&self.state_dir, epoch_number)?;

        let dest_dir = machine_path(&self.state_dir, &state_hash);
        if !dest_dir.exists() {
            machine_to_snapshot.store(&dest_dir)?;
        }

        let tx = self.connection.transaction().map_err(anyhow::Error::from)?;

        rollup_data::insert_snapshot(&tx, epoch_number, &state_hash, &dest_dir)?;
        rollup_data::insert_settlement_info(&tx, settlement, epoch_number)?;

        if epoch_number >= 2 {
            rollup_data::gc_old_epochs(&tx, epoch_number - 2)?;
        }

        tx.commit().map_err(anyhow::Error::from)?;

        Ok(())
    }

    fn latest_snapshot(&mut self) -> Result<crate::rollups_machine::RollupsMachine> {
        let (path, epoch_number) = rollup_data::latest_snapshot_path(&self.connection)?;
        Ok(RollupsMachine::new(&path, epoch_number, 0)?)
    }

    fn snapshot(&mut self, epoch_number: u64) -> Result<Option<RollupsMachine>> {
        let ret = if let Some(path) =
            rollup_data::snapshot_path_for_epoch(&self.connection, epoch_number)?
        {
            Some(RollupsMachine::new(&path, epoch_number, 0)?)
        } else {
            None
        };

        Ok(ret)
    }

    //
    // Directory
    //

    fn snapshot_dir(&mut self, epoch_number: u64) -> Result<Option<PathBuf>> {
        rollup_data::snapshot_path_for_epoch(&self.connection, epoch_number)
    }

    fn epoch_directory(&mut self, epoch_number: u64) -> Result<PathBuf> {
        create_epoch_dir(&self.state_dir, epoch_number)
    }
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

    use crate::Proof;

    use super::*;

    fn setup() -> (tempfile::TempDir, PersistentStateAccess) {
        let state_dir_ = tempfile::tempdir().unwrap();
        let state_dir = state_dir_.path();

        let machine_path = state_dir.join("_my_machine_image");
        let mut machine = Machine::create(
            &MachineConfig::new_with_ram(RAMConfig {
                length: 134217728,
                image_filename: "../../../test/programs/linux.bin".into(),
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

        let settlement_1 = Settlement {
            computation_hash: [1; 32].into(),
            output_merkle: [2; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };

        access.finish_epoch(&settlement_1, &mut initial_snapshot)?;
        assert_eq!(access.latest_snapshot()?.epoch(), 1);

        assert!(
            access.machine_state_hash(0, 0)?.is_none(),
            "machine state hash shouldn't exist"
        );
        assert!(
            access.machine_state_hashes(0)?.is_empty(),
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

        access.add_machine_state_hashes(0, 0, &[commitment_leaf_1.clone()])?;

        assert_eq!(
            access.machine_state_hash(0, 0)?.unwrap(),
            commitment_leaf_1,
            "machine state 1 data should match"
        );
        assert_eq!(
            access.machine_state_hashes(0)?.len(),
            1,
            "machine state 1 count shouldn't exist"
        );

        access.add_machine_state_hashes(0, 1, &[commitment_leaf_2.clone()])?;

        assert_eq!(
            access.machine_state_hash(0, 1)?.unwrap(),
            commitment_leaf_2,
            "machine state 2 data should match"
        );
        assert_eq!(
            access.machine_state_hashes(0)?.len(),
            2,
            "machine state 2 count shouldn't exist"
        );

        assert!(
            access.settlement_info(0)?.is_none(),
            "computation_hash shouldn't exist"
        );

        let settlement_2 = Settlement {
            computation_hash: [3; 32].into(),
            output_merkle: [4; 32],
            output_proof: Proof::new(vec![[0; 32]]),
        };

        access.finish_epoch(&settlement_2, &mut initial_snapshot)?;
        assert_eq!(access.latest_snapshot()?.epoch(), 2);

        assert_eq!(
            access.settlement_info(2)?.unwrap(),
            settlement_2,
            "settlement info of epoch 0 should match"
        );

        Ok(())
    }
}
