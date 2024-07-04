// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;

use error::{MachineRunnerError, Result};
use std::{path::Path, sync::Arc, time::Duration};

use cartesi_compute_core::{
    machine::constants::{LOG2_EMULATOR_SPAN, LOG2_INPUT_SPAN, LOG2_UARCH_SPAN},
    merkle::{Digest, MerkleBuilder},
    utils::arithmetic::max_uint,
};
use cartesi_machine::{break_reason, configuration::RuntimeConfig, htif, machine::Machine};
use rollups_state_manager::{InputId, StateManager};

// gap of each leaf in the commitment tree, should use the same value as CanonicalConstants.sol:log2step(0)
const LOG2_STRIDE: u64 = 49;

pub struct MachineRunner<SM: StateManager> {
    machine: Machine,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    _snapshot_frequency: Duration,

    epoch_number: u64,
    next_input_index_in_epoch: u64,
    state_hash_index_in_epoch: u64,
}

impl<SM: StateManager + std::fmt::Debug> MachineRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        state_manager: Arc<SM>,
        initial_machine: &str,
        sleep_duration: u64,
        snapshot_frequency: u64,
    ) -> Result<Self, SM> {
        let (snapshot, epoch_number, next_input_index_in_epoch) = match state_manager
            .latest_snapshot()
            .map_err(|e| MachineRunnerError::StateManagerError(e))?
        {
            Some(r) => (r.0, r.1, r.2 + 1),
            None => (initial_machine.to_string(), 0, 0),
        };

        let machine = Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?;

        Ok(Self {
            machine,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            _snapshot_frequency: Duration::from_secs(snapshot_frequency),
            epoch_number,
            next_input_index_in_epoch,
            state_hash_index_in_epoch: 0,
        })
    }

    pub fn start(&mut self) -> Result<(), SM> {
        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            std::thread::sleep(self.sleep_duration);
        }
        // TODO: snapshot after some time
    }

    fn process_rollup(&mut self) -> Result<(), SM> {
        // process all inputs that are currently availalble
        loop {
            self.advance_epoch()?;
            let latest_epoch = self
                .state_manager
                .epoch_count()
                .map_err(|e| MachineRunnerError::StateManagerError(e))?;

            if self.epoch_number == latest_epoch {
                break Ok(());
            } else {
                assert!(self.epoch_number < latest_epoch);

                let commitment = self.build_commitment()?;
                self.save_commitment(&commitment)?;

                // end of current epoch
                self.epoch_number += 1;
                self.next_input_index_in_epoch = 0;
                self.state_hash_index_in_epoch = 0;
            }
        }
    }

    fn advance_epoch(&mut self) -> Result<(), SM> {
        loop {
            let next = self
                .state_manager
                .input(&InputId {
                    epoch_number: self.epoch_number,
                    input_index_in_epoch: self.next_input_index_in_epoch,
                })
                .map_err(|e| MachineRunnerError::StateManagerError(e))?;

            match next {
                Some(input) => {
                    self.process_input(&input.data)?;
                    self.next_input_index_in_epoch += 1;
                }
                None => break Ok(()),
            }
        }
    }

    /// calculate computation hash for `self.epoch_number`
    fn build_commitment(&self) -> Result<Vec<u8>, SM> {
        // get all state hashes with repetitions for `self.epoch_number`
        let state_hashes = self
            .state_manager
            .machine_state_hashes(self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;

        let computation_hash = {
            if state_hashes.len() == 0 {
                // no inputs in current epoch, reuse claim from previous epoch
                self.state_manager
                    .computation_hash(self.epoch_number - 1)
                    .map_err(|e| MachineRunnerError::StateManagerError(e))?
                    .unwrap()
            } else {
                let mut builder = MerkleBuilder::default();
                let mut total_repetitions = 0;
                for state_hash in &state_hashes {
                    total_repetitions += state_hash.1;
                    builder.add_with_repetition(
                        Digest::from_digest(&state_hash.0)?,
                        state_hash.1.into(),
                    );
                }

                let stride_count_in_epoch =
                    max_uint(LOG2_INPUT_SPAN + LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);
                builder.add_with_repetition(
                    Digest::from_digest(&state_hashes.last().unwrap().0)?,
                    (stride_count_in_epoch - total_repetitions + 1).into(),
                );

                let tree = builder.build();
                tree.root_hash().slice().to_vec()
            }
        };

        Ok(computation_hash)
    }

    fn save_commitment(&self, computation_hash: &[u8]) -> Result<(), SM> {
        self.state_manager
            .add_computation_hash(computation_hash, self.epoch_number)
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;

        Ok(())
    }

    fn process_input(&mut self, data: &[u8]) -> Result<(), SM> {
        let big_steps_in_stride = max_uint(LOG2_STRIDE - LOG2_UARCH_SPAN);
        let stride_count_in_input = max_uint(LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN - LOG2_STRIDE);

        self.feed_input(data)?;
        self.run_machine(big_steps_in_stride)?;

        let mut i: u64 = 0;
        while !self.machine.read_iflags_y()? {
            self.add_state_hash(1)?;
            i += 1;
            self.run_machine(big_steps_in_stride)?;
        }
        self.add_state_hash(stride_count_in_input - i)?;

        Ok(())
    }

    fn feed_input(&mut self, input: &[u8]) -> Result<(), SM> {
        self.machine
            .send_cmio_response(htif::fromhost::ADVANCE_STATE, input)?;
        Ok(())
    }

    fn run_machine(&mut self, cycles: u64) -> Result<(), SM> {
        let mcycle = self.machine.read_mcycle()?;

        loop {
            let reason = self.machine.run(mcycle + cycles)?;
            match reason {
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,
                break_reason::YIELDED_MANUALLY | break_reason::REACHED_TARGET_MCYCLE => {
                    break Ok(())
                }
                _ => break Err(MachineRunnerError::MachineRunFail { reason }),
            }
        }
    }

    fn add_state_hash(&mut self, repetitions: u64) -> Result<(), SM> {
        let machine_state_hash = self.machine.get_root_hash()?;
        self.state_manager
            .add_machine_state_hash(
                machine_state_hash.as_bytes(),
                self.epoch_number,
                self.state_hash_index_in_epoch,
                repetitions,
            )
            .map_err(|e| MachineRunnerError::StateManagerError(e))?;
        self.state_hash_index_in_epoch += 1;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use cartesi_rollups_contracts::inputs::EvmAdvanceCall as NewEvmAdvanceCall;
    use ethers::{
        abi::AbiEncode,
        types::{Address, U256},
    };
    use rollups_state_manager::{Epoch, Input, InputId, StateManager};
    use std::{str::FromStr, sync::Arc};
    use thiserror::Error;

    use crate::MachineRunner;

    #[derive(Error, Debug)]
    pub enum MockStateAccessError {}
    type Result<T> = std::result::Result<T, MockStateAccessError>;

    #[derive(Debug)]
    struct MockStateAccess {
        // let computation_hash: &[u8] = machine_state_hashes[epoch_number]
        computation_hash: Vec<Vec<u8>>,
        // let input: &[u8] = inputs[epoch_number][input_index_in_epoch]
        inputs: Vec<Vec<Vec<u8>>>,
        // let (machine_state_hash, repetition): (&[u8], u64) =
        //      machine_state_hashes[epoch_number][state_hash_index_in_epoch]
        machine_state_hashes: Vec<Vec<(Vec<u8>, u64)>>,
    }

    impl MockStateAccess {
        pub fn new() -> Self {
            Self {
                computation_hash: Vec::new(),
                inputs: Vec::new(),
                machine_state_hashes: Vec::new(),
            }
        }
    }

    impl StateManager for MockStateAccess {
        type Error = MockStateAccessError;

        fn epoch(&self, _epoch_number: u64) -> Result<Option<Epoch>> {
            panic!("epoch not implemented in mock version");
        }

        fn epoch_count(&self) -> Result<u64> {
            Ok(self.inputs.len() as u64)
        }

        fn input(&self, id: &InputId) -> Result<Option<Input>> {
            let (epoch_number, input_index_in_epoch) =
                (id.epoch_number as usize, id.input_index_in_epoch as usize);

            if (self.inputs.len() <= epoch_number)
                || (self.inputs[epoch_number].len() <= input_index_in_epoch)
            {
                return Ok(None);
            }

            let input = self.inputs[epoch_number][input_index_in_epoch].clone();
            Ok(Some(Input {
                id: id.clone(),
                data: input,
            }))
        }

        fn input_count(&self, epoch_number: u64) -> Result<u64> {
            let input_count = self.inputs[epoch_number as usize].len();
            Ok(input_count as u64)
        }

        fn latest_processed_block(&self) -> Result<u64> {
            panic!("latest_processed_block not implemented in mock version");
        }

        fn insert_consensus_data<'a>(
            &self,
            _last_processed_block: u64,
            _inputs: impl Iterator<Item = &'a Input>,
            _epochs: impl Iterator<Item = &'a Epoch>,
        ) -> Result<()> {
            panic!("insert_consensus_data not implemented in mock version");
        }

        fn add_machine_state_hash(
            &self,
            machine_state_hash: &[u8],
            epoch_number: u64,
            state_hash_index_in_epoch: u64,
            repetitions: u64,
        ) -> Result<()> {
            println!(
                "machine_state_hash at epoch {}, index {}, rep {} is: {}",
                epoch_number,
                state_hash_index_in_epoch,
                repetitions,
                hex::encode(&machine_state_hash),
            );
            let (h, r) = &self.machine_state_hashes[epoch_number as usize]
                [state_hash_index_in_epoch as usize];

            assert_eq!(h, machine_state_hash, "machine state hash should match");
            assert_eq!(*r, repetitions, "repetition should match");

            Ok(())
        }

        fn computation_hash(&self, epoch_number: u64) -> Result<Option<Vec<u8>>> {
            let epoch_number = epoch_number as usize;

            Ok(self.computation_hash.get(epoch_number).map(|h| h.clone()))
        }

        fn add_computation_hash(&self, _computation_hash: &[u8], _epoch_number: u64) -> Result<()> {
            panic!("add_computation_hash not implemented in mock version");
        }

        fn add_snapshot(
            &self,
            _path: &str,
            _epoch_number: u64,
            _input_index_in_epoch: u64,
        ) -> Result<()> {
            panic!("add_snapshot not implemented in mock version");
        }

        fn machine_state_hash(
            &self,
            _epoch_number: u64,
            _state_hash_index_in_epoch: u64,
        ) -> Result<(Vec<u8>, u64)> {
            panic!("machine_state_hash not implemented in mock version");
        }

        // returns all state hashes and their repetitions in acending order of `state_hash_index_in_epoch`
        fn machine_state_hashes(&self, epoch_number: u64) -> Result<Vec<(Vec<u8>, u64)>> {
            let epoch_number = epoch_number as usize;

            if self.machine_state_hashes.len() <= epoch_number {
                return Ok(Vec::new());
            }

            let machin_state_hashes = self.machine_state_hashes[epoch_number].clone();

            Ok(machin_state_hashes)
        }

        fn latest_snapshot(&self) -> Result<Option<(String, u64, u64)>> {
            Ok(None)
        }
    }

    fn hex_to_bytes(s: &str) -> Option<Vec<u8>> {
        if s.len() % 2 == 0 {
            (0..s.len())
                .step_by(2)
                .map(|i| {
                    s.get(i..i + 2)
                        .and_then(|sub| u8::from_str_radix(sub, 16).ok())
                })
                .collect()
        } else {
            None
        }
    }

    fn load_machine_state_hashes() -> (Vec<(Vec<u8>, u64)>, Vec<u8>) {
        // this file stores all the machine state hashes and their repetitions of stride at each line,
        // machine state hash and its repetition are delimited by `space character`
        // and the computation hash of above machine state hashes is at last line
        // [
        //     hash_0 rep_0
        //     hash_1 rep_1
        //     hash_2 rep_2
        //     hash_3 rep_3
        //     computation_hash
        // ]
        let machine_state_hashes_str = include_str!("../test-files/machine_state_hashes.test");
        let mut machine_state_hashes_hex: Vec<&str> =
            machine_state_hashes_str.split("\n").collect();

        // get commitment from last line
        let commitment_str = machine_state_hashes_hex.pop().unwrap();
        let commitment = hex_to_bytes(commitment_str).unwrap();

        let machine_state_hashes = machine_state_hashes_hex
            .iter()
            .map(|h| {
                let hash_and_rep: Vec<&str> = (*h).split(" ").collect();
                (
                    hex_to_bytes(hash_and_rep[0]).unwrap(),
                    hash_and_rep[1].parse().unwrap(),
                )
            })
            .collect();

        (machine_state_hashes, commitment)
    }

    // TODO: use actual call type from the rollups_contract crate
    /// this is the old call format,
    /// it should be replaced by the actual `EvmAdvance` after it's deployed and published
    #[derive(
        Clone,
        ethers::contract::EthCall,
        ethers::contract::EthDisplay,
        serde::Serialize,
        serde::Deserialize,
        Default,
        Debug,
        PartialEq,
        Eq,
        Hash,
    )]
    #[ethcall(
        name = "EvmAdvance",
        abi = "EvmAdvance(uint256,address,address,uint256,uint256,uint256,bytes)"
    )]
    pub struct EvmAdvanceCall {
        pub chain_id: ::ethers::core::types::U256,
        pub app_contract: ::ethers::core::types::Address,
        pub msg_sender: ::ethers::core::types::Address,
        pub block_number: ::ethers::core::types::U256,
        pub block_timestamp: ::ethers::core::types::U256,
        pub index: ::ethers::core::types::U256,
        pub payload: ::ethers::core::types::Bytes,
    }

    fn load_inputs() -> Vec<Vec<u8>> {
        // this file stores all the inputs for one epoch
        let inputs_str = include_str!("../test-files/inputs.test");
        let inputs_hex: Vec<&str> = inputs_str.split("\n").collect();

        let chain_id = U256::from(31337);
        let app_contract = Address::from_str("0x0000000000000000000000000000000000000002").unwrap();
        let msg_sender = Address::from_str("0x0000000000000000000000000000000000000003").unwrap();
        let block_number = U256::from(4);
        let block_timestamp = U256::from(5);
        let inputs = inputs_hex
            .iter()
            .enumerate()
            .map(|(i, h)| {
                EvmAdvanceCall {
                    chain_id,
                    app_contract,
                    msg_sender,
                    block_number,
                    block_timestamp,
                    index: U256::from(i),
                    payload: hex_to_bytes(*h).unwrap().into(),
                }
                .encode()
            })
            .collect();

        inputs
    }

    #[tokio::test]
    async fn test_input_advance() -> std::result::Result<(), Box<dyn std::error::Error>> {
        let (machine_state_hashes, commitment) = load_machine_state_hashes();
        let inputs = load_inputs();

        assert_eq!(
            machine_state_hashes.len(),
            inputs.len(),
            "number of machine state hashes and inputs should match"
        );

        let mut state_manager = MockStateAccess::new();
        // preload inputs from file
        state_manager.inputs.push(inputs);
        // preload machine state hashes for epoch 0
        state_manager
            .machine_state_hashes
            .push(machine_state_hashes);
        let mut runner = MachineRunner::new(Arc::new(state_manager), "/app/echo", 10, 10)?;

        runner.advance_epoch()?;
        assert_eq!(
            runner.build_commitment()?,
            commitment,
            "computation hash should match"
        );

        Ok(())
    }
}
