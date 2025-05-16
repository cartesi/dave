// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;
mod find_contract_creation;

use crate::error::{ProviderErrors, Result};

use alloy::{
    contract::{Error, Event},
    eips::BlockNumberOrTag::Finalized,
    hex::ToHexExt,
    primitives::{Address, U256},
    providers::{DynProvider, Provider},
    rpc::types::{Log, Topic},
    sol_types::SolEvent,
};
use async_recursion::async_recursion;
use cartesi_machine::types::Hash;
use find_contract_creation::find_contract_creation_block;
use log::{debug, info, trace};
use num_traits::cast::ToPrimitive;
use rollups_state_manager::sync::Watch;
use std::ops::ControlFlow;
use std::{
    fmt,
    iter::Peekable,
    marker::{Send, Sync},
    time::Duration,
};

use cartesi_dave_contracts::daveconsensus::DaveConsensus::{self, EpochSealed};
use cartesi_rollups_contracts::{application::Application, inputbox::InputBox::InputAdded};
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

#[derive(Debug, Clone, Copy)]
pub struct AddressBook {
    /// address of app
    pub app: Address,
    /// address of Dave consensus
    pub consensus: Address,
    /// address of input box
    pub input_box: Address,
    /// earliest block number where contracts exist
    pub genesis_block_number: u64,
    /// initial state hash of application
    pub initial_hash: Hash,
}

impl fmt::Display for AddressBook {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "App Address: {}", self.app)?;
        writeln!(f, "Consensus Address: {}", self.consensus)?;
        writeln!(f, "Input Box Address: {}", self.input_box)?;
        writeln!(f, "Genesis Block Number: {}", self.genesis_block_number)?;
        writeln!(f, "Initial Hash: {}", alloy::hex::encode(self.initial_hash))?;
        Ok(())
    }
}

impl AddressBook {
    // fetch other addresses from application
    pub async fn new(app: Address, provider: &impl Provider) -> Self {
        let application_contract = Application::new(app, provider);

        let consensus = application_contract
            .getOutputsMerkleRootValidator()
            .call()
            .await
            .expect("fail to query consensus address")
            ._0;

        let input_box = {
            let consensus_contract = DaveConsensus::new(consensus, provider);
            consensus_contract
                .getInputBox()
                .call()
                .await
                .expect("fail to query input box address")
                ._0
        };

        let initial_hash = Self::initial_hash(consensus, provider).await;
        let input_box_created_block = find_contract_creation_block(provider, input_box)
            .await
            .expect("fail to get input_box creation block");

        Self {
            app,
            consensus,
            input_box,
            genesis_block_number: input_box_created_block,
            initial_hash,
        }
    }

    pub async fn initial_hash(consensus: Address, provider: &impl Provider) -> Hash {
        let consensus_contract = DaveConsensus::new(consensus, provider);

        let consensus_created_block = find_contract_creation_block(provider, consensus)
            .await
            .expect("fail to get consensus creation block");

        debug!(
            "consensus created {} at {}",
            consensus_created_block, consensus
        );

        let sealed_epochs = consensus_contract
            .EpochSealed_filter()
            .address(consensus)
            .from_block(consensus_created_block)
            .to_block(consensus_created_block)
            .query()
            .await
            .expect("fail to get sealed epoch 0");
        assert_eq!(sealed_epochs.len(), 1);

        sealed_epochs[0].0.initialMachineStateHash.into()
    }
}

pub struct BlockchainReader<SM: StateManager> {
    state_manager: SM,
    provider: DynProvider,
    address_book: AddressBook,
    input_reader: EventReader<InputAdded>,
    epoch_reader: EventReader<EpochSealed>,
    sleep_duration: Duration,
}

impl<SM: StateManager> BlockchainReader<SM> {
    pub fn new(
        state_manager: SM,
        provider: DynProvider,
        address_book: AddressBook,
        sleep_duration: Duration,
    ) -> Self {
        Self {
            state_manager,
            address_book,
            provider,
            input_reader: EventReader::<InputAdded>::default(),
            epoch_reader: EventReader::<EpochSealed>::default(),
            sleep_duration,
        }
    }

    pub fn start(self, watch: Watch) -> Result<()> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("`BlockchainReader` runtime build failure");

        rt.block_on(async move { self.execution_loop(watch).await })
    }

    async fn execution_loop(mut self, watch: Watch) -> Result<()> {
        // TODO set genesis at main.rs
        let input_box_creation =
            find_contract_creation_block(&self.provider, self.address_book.input_box)
                .await
                .map_err(|e| ProviderErrors(vec![Error::TransportError(e)]))?;
        let latest_processed = self.state_manager.latest_processed_block()?;
        if input_box_creation > latest_processed {
            self.state_manager.set_genesis(input_box_creation)?;
        }

        loop {
            let current_block = latest_finalized_block(&self.provider).await?;
            let prev_block = self.state_manager.latest_processed_block()?;

            if current_block > prev_block {
                self.advance(prev_block, current_block).await?;
            }

            if matches!(watch.wait(self.sleep_duration), ControlFlow::Break(_)) {
                break Ok(());
            }
        }
    }

    async fn advance(&mut self, prev_block: u64, current_block: u64) -> Result<()> {
        let (inputs, epochs) = self.collect_events(prev_block, current_block).await?;

        self.state_manager.insert_consensus_data(
            current_block,
            inputs.iter().collect::<Vec<&Input>>().into_iter(),
            epochs.iter().collect::<Vec<&Epoch>>().into_iter(),
        )?;

        Ok(())
    }

    async fn collect_events(
        &mut self,
        prev_block: u64,
        current_block: u64,
    ) -> Result<(Vec<Input>, Vec<Epoch>)> {
        // read sealed epochs from blockchain
        let sealed_epochs: Vec<Epoch> = self
            .collect_sealed_epochs(prev_block, current_block)
            .await?;

        let last_sealed_epoch_opt = self.state_manager.last_sealed_epoch()?;
        let mut merged_sealed_epochs = Vec::new();
        if let Some(last_sealed_epoch) = last_sealed_epoch_opt {
            merged_sealed_epochs.push(last_sealed_epoch);
        }
        merged_sealed_epochs.extend(sealed_epochs.clone());
        let merged_sealed_epochs_iter = merged_sealed_epochs
            .iter()
            .collect::<Vec<&Epoch>>()
            .into_iter();

        // read inputs from blockchain
        let inputs = self
            .collect_inputs(prev_block, current_block, merged_sealed_epochs_iter)
            .await?;

        Ok((inputs, sealed_epochs))
    }

    async fn collect_sealed_epochs(
        &self,
        prev_block: u64,
        current_block: u64,
    ) -> Result<Vec<Epoch>> {
        Ok(self
            .epoch_reader
            .next(
                &self.provider,
                None,
                &self.address_book.consensus,
                prev_block,
                current_block,
            )
            .await?
            .iter()
            .map(|(e, meta)| {
                let epoch = Epoch {
                    epoch_number: e
                        .epochNumber
                        .to_u64()
                        .expect("fail to convert epoch number"),
                    input_index_boundary: e
                        .inputIndexUpperBound
                        .to_u64()
                        .expect("fail to convert epoch boundary"),
                    root_tournament: e.tournament,
                    block_created_number: meta.block_number.expect("block number should exist"),
                };
                info!(
                    "epoch received: epoch_number {}, input_index_boundary {}, root_tournament {}",
                    epoch.epoch_number, epoch.input_index_boundary, epoch.root_tournament
                );
                epoch
            })
            .collect())
    }

    async fn collect_inputs(
        &mut self,
        prev_block: u64,
        current_block: u64,
        sealed_epochs_iter: impl Iterator<Item = &Epoch>,
    ) -> Result<Vec<Input>> {
        // read new inputs from blockchain
        let input_events: Vec<_> = self
            .input_reader
            .next(
                &self.provider,
                Some(&self.address_book.app.into_word().into()),
                &self.address_book.input_box,
                prev_block,
                current_block,
            )
            .await?
            .into_iter()
            .map(|i| i.0)
            .collect();

        let last_input = self.state_manager.last_input()?;

        let (mut next_input_index_in_epoch, mut last_input_epoch_number) = {
            match last_input {
                // continue inserting inputs from where it was left
                Some(input) => (input.input_index_in_epoch + 1, input.epoch_number),
                // first ever input for the application
                None => (0, 0),
            }
        };

        let mut inputs = vec![];
        let mut input_events_peekable = input_events.iter().peekable();
        for epoch in sealed_epochs_iter {
            if last_input_epoch_number > epoch.epoch_number {
                continue;
            }
            // iterate through newly sealed epochs, fill in the inputs accordingly
            let inputs_of_epoch = self.construct_input_ids(
                epoch.epoch_number,
                epoch.input_index_boundary,
                &mut next_input_index_in_epoch,
                &mut input_events_peekable,
            );

            inputs.extend(inputs_of_epoch);
            last_input_epoch_number = epoch.epoch_number + 1;
        }

        // all remaining inputs belong to an epoch that's not sealed yet
        let inputs_of_epoch = self.construct_input_ids(
            last_input_epoch_number,
            u64::MAX,
            &mut next_input_index_in_epoch,
            &mut input_events_peekable,
        );

        inputs.extend(inputs_of_epoch);

        Ok(inputs)
    }

    fn construct_input_ids<'a>(
        &self,
        epoch_number: u64,
        input_index_boundary: u64,
        next_input_index_in_epoch: &mut u64,
        input_events_peekable: &mut Peekable<impl Iterator<Item = &'a InputAdded>>,
    ) -> Vec<Input> {
        let input_index_boundary = U256::from(input_index_boundary);
        let mut inputs = vec![];

        while let Some(input_added) = input_events_peekable.peek() {
            if input_added.index >= U256::from(input_index_boundary) {
                break;
            }
            let input = Input {
                id: InputId {
                    epoch_number,
                    input_index_in_epoch: *next_input_index_in_epoch,
                },
                data: input_added.input.to_vec(),
            };
            info!(
                "input received: epoch_number {}, input_index {}",
                input.id.epoch_number, input.id.input_index_in_epoch,
            );
            trace!("input data 0x{}", input.data.encode_hex());

            input_events_peekable.next();
            *next_input_index_in_epoch += 1;
            inputs.push(input);
        }
        // input index in epoch should be reset when a new epoch starts
        *next_input_index_in_epoch = 0;

        inputs
    }
}

pub struct EventReader<E: SolEvent + Send + Sync> {
    __phantom: std::marker::PhantomData<E>,
}

impl<E: SolEvent + Send + Sync> EventReader<E> {
    async fn next(
        &self,
        provider: &impl Provider,
        topic1: Option<&Topic>,
        read_from: &Address,
        prev_finalized: u64,
        current_finalized: u64,
    ) -> std::result::Result<Vec<(E, Log)>, ProviderErrors> {
        assert!(current_finalized > prev_finalized);

        let logs = get_events(
            provider,
            topic1,
            read_from,
            // blocks are inclusive on both ends
            prev_finalized + 1,
            current_finalized,
        )
        .await
        .map_err(ProviderErrors)?;

        Ok(logs)
    }
}

impl<E: SolEvent + Send + Sync> Default for EventReader<E> {
    fn default() -> Self {
        Self {
            __phantom: std::marker::PhantomData,
        }
    }
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
async fn get_events<E: SolEvent + Send + Sync>(
    provider: &impl Provider,
    topic1: Option<&Topic>,
    read_from: &Address,
    start_block: u64,
    end_block: u64,
) -> std::result::Result<Vec<(E, Log)>, Vec<Error>> {
    get_events_rec(provider, topic1, read_from, start_block, end_block).await
}

#[async_recursion]
async fn get_events_rec<E: SolEvent + Send + Sync>(
    provider: &impl Provider,
    topic1: Option<&Topic>,
    read_from: &Address,
    start_block: u64,
    end_block: u64,
) -> std::result::Result<Vec<(E, Log)>, Vec<Error>> {
    // TODO: partition log queries if range too large
    let event: Event<(), _, E> = {
        let mut e = Event::new_sol(provider, read_from)
            .from_block(start_block)
            .to_block(end_block)
            .event(E::SIGNATURE);

        if let Some(t) = topic1 {
            e = e.topic1(t.clone());
        }

        e
    };

    match event.query().await {
        Ok(l) => Ok(l),
        Err(e) => {
            if should_retry_with_partition(&e) {
                let middle = {
                    let blocks = 1 + end_block - start_block;
                    let half = blocks / 2;
                    start_block + half - 1
                };

                let first_res =
                    get_events_rec(provider, topic1, read_from, start_block, middle).await;
                let second_res =
                    get_events_rec(provider, topic1, read_from, middle + 1, end_block).await;

                match (first_res, second_res) {
                    (Ok(mut first), Ok(second)) => {
                        first.extend(second);
                        Ok(first)
                    }

                    (Err(mut first), Err(second)) => {
                        first.extend(second);
                        Err(first)
                    }

                    (Err(err), _) | (_, Err(err)) => Err(err),
                }
            } else {
                Err(vec![e])
            }
        }
    }
}

async fn latest_finalized_block(
    provider: &impl Provider,
) -> std::result::Result<u64, ProviderErrors> {
    let block_number = provider
        .get_block(Finalized.into())
        .await
        .map_err(|e| ProviderErrors(vec![Error::TransportError(e)]))?
        .expect("block is empty")
        .header
        .number;

    Ok(block_number)
}

fn should_retry_with_partition(err: &Error) -> bool {
    // infura limit error code: -32005
    let query_limit_error_codes = [-32005];
    for code in query_limit_error_codes {
        let s = format!("{:?}", err);
        if s.contains(&code.to_string()) {
            return true;
        }
    }

    false
}

#[cfg(test)]
mod test_utils;

#[cfg(test)]
mod blockchain_reader_tests {
    use std::{sync::Arc, thread};

    use crate::*;

    use alloy::{
        primitives::Address,
        providers::{DynProvider, ProviderBuilder},
        sol_types::{SolCall, SolValue},
    };
    use cartesi_dave_contracts::daveconsensus::DaveConsensus::{self, EpochSealed};
    use cartesi_dave_merkle::Digest;
    use cartesi_machine::{
        Machine,
        config::{
            machine::{MachineConfig, RAMConfig},
            runtime::RuntimeConfig,
        },
    };
    use cartesi_rollups_contracts::{
        inputbox::InputBox::{self, InputAdded},
        inputs::Inputs::EvmAdvanceCall,
    };
    use rollups_state_manager::persistent_state_access::PersistentStateAccess;

    use tokio::time::{Duration, sleep};

    type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
    const INPUT_PAYLOAD: &str = "Hello!";
    const INPUT_PAYLOAD2: &str = "Hello Two!";

    use crate::test_utils::*;

    fn create_provider(url: &str) -> DynProvider {
        let url = url.parse().unwrap();
        ProviderBuilder::new().on_http(url).erased()
    }

    fn create_epoch_reader() -> EventReader<EpochSealed> {
        EventReader::<EpochSealed>::default()
    }

    fn create_input_reader() -> EventReader<InputAdded> {
        EventReader::<InputAdded>::default()
    }

    fn state_access() -> (tempfile::TempDir, PersistentStateAccess) {
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

    async fn add_input(
        inputbox: &InputBox::InputBoxInstance<(), DynProvider>,
        application_address: Address,
        input_payload: &'static str,
        count: usize,
    ) -> Result<()> {
        for _ in 0..count {
            inputbox
                .addInput(application_address, input_payload.as_bytes().into())
                .max_fee_per_gas(10000000000)
                .send()
                .await?
                .watch()
                .await?;
        }
        Ok(())
    }

    async fn read_epochs_until_count(
        url: &str,
        consensus_address: &Address,
        epoch_reader: &EventReader<EpochSealed>,
        count: usize,
    ) -> Result<Vec<EpochSealed>> {
        let provider = create_provider(url);
        let mut read_epochs = Vec::new();
        while read_epochs.len() != count {
            // latest finalized block must be greater than 0
            let latest_finalized_block = std::cmp::max(1, latest_finalized_block(&provider).await?);

            read_epochs = epoch_reader
                .next(
                    &provider,
                    None,
                    consensus_address,
                    0,
                    latest_finalized_block,
                )
                .await?
                .into_iter()
                .map(|x| x.0)
                .collect();
            // wait a few seconds for the input added block to be finalized
            sleep(Duration::from_secs(1)).await;
        }

        Ok(read_epochs)
    }

    async fn read_inputs_until_count(
        url: &str,
        inputbox_address: &Address,
        application_address: &Address,
        input_reader: &EventReader<InputAdded>,
        count: usize,
    ) -> Result<Vec<InputAdded>> {
        let provider = create_provider(url);
        let mut read_inputs = Vec::new();
        while read_inputs.len() != count {
            // latest finalized block must be greater than 0
            let latest_finalized_block = std::cmp::max(1, latest_finalized_block(&provider).await?);

            read_inputs = input_reader
                .next(
                    &provider,
                    Some(&application_address.into_word().into()),
                    inputbox_address,
                    0,
                    latest_finalized_block,
                )
                .await?
                .into_iter()
                .map(|x| x.0)
                .collect();
            // wait a few seconds for the input added block to be finalized
            sleep(Duration::from_secs(1)).await;
        }

        Ok(read_inputs)
    }

    async fn read_inputs_from_db_until_count<SM: StateManager>(
        state_manager: &mut SM,
        epoch_number: u64,
        count: usize,
    ) -> Result<Vec<Vec<u8>>> {
        let mut read_inputs = Vec::new();
        while read_inputs.len() != count {
            read_inputs = state_manager.inputs(epoch_number)?;
            // wait a few seconds for the db to be updated
            sleep(Duration::from_secs(1)).await;
        }

        Ok(read_inputs)
    }

    #[tokio::test]
    async fn test_input_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider();
        let inputbox = InputBox::new(address_book.input_box, provider.clone());

        let input_count_1 = 2;
        // Inputbox is deployed with 1 input already
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_1).await?;

        let input_reader = create_input_reader();
        let mut read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
            &address_book.app,
            &input_reader,
            1 + input_count_1,
        )
        .await?;
        assert_eq!(read_inputs.len(), 1 + input_count_1);

        let received_payload =
            EvmAdvanceCall::abi_decode(read_inputs.last().unwrap().input.as_ref(), true)?;
        assert_eq!(received_payload.payload.as_ref(), INPUT_PAYLOAD.as_bytes());

        let input_count_2 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD2, input_count_2).await?;
        read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
            &address_book.app,
            &input_reader,
            1 + input_count_1 + input_count_2,
        )
        .await?;
        assert_eq!(read_inputs.len(), 1 + input_count_1 + input_count_2);

        let received_payload =
            EvmAdvanceCall::abi_decode(read_inputs.last().unwrap().input.as_ref(), true)?;
        assert_eq!(received_payload.payload.as_ref(), INPUT_PAYLOAD2.as_bytes());

        drop(anvil);
        Ok(())
    }

    #[tokio::test]
    async fn test_epoch_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider();
        let daveconsensus = DaveConsensus::new(address_book.consensus, &provider);

        let epoch_reader = create_epoch_reader();
        let read_epochs =
            read_epochs_until_count(&anvil.endpoint(), daveconsensus.address(), &epoch_reader, 1)
                .await?;
        assert_eq!(read_epochs.len(), 1);
        assert_eq!(
            &read_epochs[0].initialMachineStateHash.abi_encode(),
            Digest::from_digest(&address_book.initial_hash)
                .unwrap()
                .slice()
        );

        drop(anvil);
        Ok(())
    }

    #[tokio::test]
    async fn test_blockchain_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider();

        let inputbox = InputBox::new(address_book.input_box, provider.clone());

        let (handle, mut state_manager) = state_access();

        // Note that inputbox is deployed with 1 input already
        // add inputs to epoch 0
        let input_count_1 = 2;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_1).await?;

        let watch = Watch::default();

        let watch_0 = watch.clone();
        let r = thread::spawn(move || {
            let blockchain_reader = BlockchainReader::new(
                PersistentStateAccess::new(handle.path()).unwrap(),
                provider,
                address_book,
                Duration::from_secs(1),
            );

            blockchain_reader.start(watch_0).unwrap();
        });

        read_inputs_from_db_until_count(&mut state_manager, 0, 1).await?;
        read_inputs_from_db_until_count(&mut state_manager, 1, input_count_1).await?;

        // add inputs ttest_blockchain_readero epoch 1
        let input_count_2 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_2).await?;
        read_inputs_from_db_until_count(&mut state_manager, 1, input_count_1 + input_count_2)
            .await?;

        // add more inputs to epoch 1
        let input_count_3 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_3).await?;
        read_inputs_from_db_until_count(
            &mut state_manager,
            1,
            input_count_1 + input_count_2 + input_count_3,
        )
        .await?;

        watch.notify(Arc::new(anyhow::anyhow!("".to_owned())));
        r.join().unwrap();
        drop(anvil);

        Ok(())
    }
}
