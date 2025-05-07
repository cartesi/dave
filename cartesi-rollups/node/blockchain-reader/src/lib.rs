// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;
mod find_contract_creation;

use crate::error::{ProviderErrors, Result};

use alloy::{
    contract::{Error, Event},
    eips::BlockNumberOrTag::Finalized,
    hex::{FromHex, ToHexExt},
    primitives::{Address, U256},
    providers::{DynProvider, Provider},
    rpc::types::{Log, Topic},
    sol_types::SolEvent,
};
use async_recursion::async_recursion;
use clap::Parser;
use error::BlockchainReaderError;
use find_contract_creation::find_contract_creation_block;
use log::{info, trace};
use num_traits::cast::ToPrimitive;
use std::{
    fmt,
    iter::Peekable,
    marker::{Send, Sync},
    sync::Arc,
    time::Duration,
};

use cartesi_dave_contracts::daveconsensus::DaveConsensus::{self, EpochSealed};
use cartesi_dave_merkle::Digest;
use cartesi_rollups_contracts::{application::Application, inputbox::InputBox::InputAdded};
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

const DEVNET_INPUT_BOX_ADDRESS: &str = "5FbDB2315678afecb367f032d93F642f64180aa3";
const DEVNET_CONSENSUS_ADDRESS: &str = "610178da211fef7d417bc0e6fed39f05609ad788";

#[derive(Debug, Clone, Parser)]
#[command(name = "cartesi_rollups_config")]
#[command(about = "Addresses of Cartesi Rollups")]
pub struct AddressBook {
    /// address of app
    #[arg(long, env, default_value_t = Address::ZERO)]
    app: Address,
    /// address of Dave consensus
    #[clap(skip)]
    pub consensus: Address,
    /// address of input box
    #[clap(skip)]
    input_box: Address,
}

impl fmt::Display for AddressBook {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "    App Address: {}", self.app)?;
        writeln!(f, "    Consensus Address: {}", self.consensus)?;
        writeln!(f, "    Input Box Address: {}", self.input_box)?;
        Ok(())
    }
}

impl AddressBook {
    // initialize `AddressBook` and return the machine initial hash of epoch 0
    pub async fn initialize(&mut self, provider: &DynProvider) -> Digest {
        let consensus_contract = {
            if self.app == Address::ZERO {
                self.consensus = Address::from_hex(DEVNET_CONSENSUS_ADDRESS)
                    .expect("fail to load consensus address");
                self.input_box = Address::from_hex(DEVNET_INPUT_BOX_ADDRESS)
                    .expect("fail to load input box address");
                DaveConsensus::new(self.consensus, provider)
            } else {
                let application = Application::new(self.app, provider);
                self.consensus = application
                    .getOutputsMerkleRootValidator()
                    .call()
                    .await
                    .expect("fail to query consensus address")
                    ._0;
                let consensus = DaveConsensus::new(self.consensus, provider);
                self.input_box = consensus
                    .getInputBox()
                    .call()
                    .await
                    .expect("fail to query input box address")
                    ._0;
                consensus
            }
        };
        let consensus_created_block = find_contract_creation_block(provider, self.consensus)
            .await
            .expect("fail to get consensus creation block");
        let sealed_epochs = consensus_contract
            .EpochSealed_filter()
            .address(self.consensus)
            .from_block(consensus_created_block)
            .to_block(consensus_created_block)
            .query()
            .await
            .expect("fail to get sealed epoch 0");
        assert!(sealed_epochs.len() == 1);
        sealed_epochs[0].0.initialMachineStateHash.into()
    }
}

pub struct BlockchainReader<SM: StateManager> {
    state_manager: Arc<SM>,
    address_book: AddressBook,
    prev_block: u64,
    provider: PartitionProvider,
    input_reader: EventReader<InputAdded>,
    epoch_reader: EventReader<EpochSealed>,
    sleep_duration: Duration,
}

impl<SM: StateManager> BlockchainReader<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub async fn new(
        state_manager: Arc<SM>,
        address_book: AddressBook,
        provider: DynProvider,
        sleep_duration: u64,
    ) -> Result<Self, SM> {
        // read from DB the block of the most recent processed
        let prev_block = {
            let input_box_creation =
                find_contract_creation_block(&provider, address_book.input_box)
                    .await
                    .map_err(|e| ProviderErrors(vec![Error::TransportError(e)]))?;

            let latest_processed = state_manager
                .latest_processed_block()
                .map_err(BlockchainReaderError::StateManagerError)?;

            std::cmp::max(input_box_creation, latest_processed)
        };

        let partition_provider = PartitionProvider::new(provider);

        Ok(Self {
            state_manager,
            address_book,
            prev_block,
            provider: partition_provider,
            input_reader: EventReader::<InputAdded>::default(),
            epoch_reader: EventReader::<EpochSealed>::default(),
            sleep_duration: Duration::from_secs(sleep_duration),
        })
    }

    pub async fn start(mut self) -> Result<(), SM> {
        loop {
            let current_block = self.provider.latest_finalized_block().await?;

            if current_block > self.prev_block {
                self.advance(self.prev_block, current_block).await?;
                self.prev_block = current_block;
            }
            tokio::time::sleep(self.sleep_duration).await;
        }
    }

    async fn advance(&self, prev_block: u64, current_block: u64) -> Result<(), SM> {
        let (inputs, epochs) = self.collect_events(prev_block, current_block).await?;

        self.state_manager
            .insert_consensus_data(
                current_block,
                inputs.iter().collect::<Vec<&Input>>().into_iter(),
                epochs.iter().collect::<Vec<&Epoch>>().into_iter(),
            )
            .map_err(BlockchainReaderError::StateManagerError)?;

        Ok(())
    }

    async fn collect_events(
        &self,
        prev_block: u64,
        current_block: u64,
    ) -> Result<(Vec<Input>, Vec<Epoch>), SM> {
        // read sealed epochs from blockchain
        let sealed_epochs: Vec<Epoch> = self
            .collect_sealed_epochs(prev_block, current_block)
            .await?;

        let last_sealed_epoch_opt = self
            .state_manager
            .last_sealed_epoch()
            .map_err(BlockchainReaderError::StateManagerError)?;
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
    ) -> Result<Vec<Epoch>, SM> {
        Ok(self
            .epoch_reader
            .next(
                None,
                &self.address_book.consensus,
                prev_block,
                current_block,
                &self.provider,
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
                    root_tournament: e.tournament.to_string(),
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
        &self,
        prev_block: u64,
        current_block: u64,
        sealed_epochs_iter: impl Iterator<Item = &Epoch>,
    ) -> Result<Vec<Input>, SM> {
        // read new inputs from blockchain
        let input_events: Vec<_> = self
            .input_reader
            .next(
                Some(&self.address_book.app.into_word().into()),
                &self.address_book.input_box,
                prev_block,
                current_block,
                &self.provider,
            )
            .await?
            .into_iter()
            .map(|i| i.0)
            .collect();

        let last_input = self
            .state_manager
            .last_input()
            .map_err(BlockchainReaderError::StateManagerError)?;

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
        topic1: Option<&Topic>,
        read_from: &Address,
        prev_finalized: u64,
        current_finalized: u64,
        provider: &PartitionProvider,
    ) -> std::result::Result<Vec<(E, Log)>, ProviderErrors> {
        assert!(current_finalized > prev_finalized);

        let logs = provider
            .get_events(
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

struct PartitionProvider {
    inner: DynProvider,
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
impl PartitionProvider {
    fn new(provider: DynProvider) -> Self {
        PartitionProvider { inner: provider }
    }

    async fn get_events<E: SolEvent + Send + Sync>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> std::result::Result<Vec<(E, Log)>, Vec<Error>> {
        self.get_events_rec(topic1, read_from, start_block, end_block)
            .await
    }

    #[async_recursion]
    async fn get_events_rec<E: SolEvent + Send + Sync>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> std::result::Result<Vec<(E, Log)>, Vec<Error>> {
        // TODO: partition log queries if range too large
        let event: Event<(), &DynProvider, E> = {
            let mut e = Event::new_sol(&self.inner, read_from)
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
                if Self::should_retry_with_partition(&e) {
                    let middle = {
                        let blocks = 1 + end_block - start_block;
                        let half = blocks / 2;
                        start_block + half - 1
                    };

                    let first_res = self
                        .get_events_rec(topic1, read_from, start_block, middle)
                        .await;
                    let second_res = self
                        .get_events_rec(topic1, read_from, middle + 1, end_block)
                        .await;

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

    async fn latest_finalized_block(&self) -> std::result::Result<u64, ProviderErrors> {
        let block_number = self
            .inner
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
}

#[cfg(test)]
mod test_utils;

#[cfg(test)]
mod blockchain_reader_tests {
    use crate::*;

    use alloy::{
        primitives::Address,
        providers::{DynProvider, ProviderBuilder},
        sol_types::{SolCall, SolValue},
    };
    use cartesi_dave_contracts::daveconsensus::DaveConsensus::{self, EpochSealed};
    use cartesi_rollups_contracts::{
        inputbox::InputBox::{self, InputAdded},
        inputs::Inputs::EvmAdvanceCall,
    };
    use rollups_state_manager::persistent_state_access::PersistentStateAccess;

    use rusqlite::Connection;
    use std::sync::Arc;
    use tokio::{
        task::spawn,
        time::{Duration, sleep},
    };

    type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
    const APP_ADDRESS: Address = Address::ZERO;
    const INPUT_PAYLOAD: &str = "Hello!";
    const INPUT_PAYLOAD2: &str = "Hello Two!";

    use crate::test_utils::*;

    fn create_partition_provider(url: &str) -> Result<PartitionProvider> {
        let url = url.parse()?;
        let provider = ProviderBuilder::new().on_http(url).erased();
        let partition_provider = PartitionProvider::new(provider);
        Ok(partition_provider)
    }

    fn create_epoch_reader() -> EventReader<EpochSealed> {
        EventReader::<EpochSealed>::default()
    }

    fn create_input_reader() -> EventReader<InputAdded> {
        EventReader::<InputAdded>::default()
    }

    async fn add_input(
        inputbox: &InputBox::InputBoxInstance<(), &DynProvider>,
        input_payload: &'static str,
        count: usize,
    ) -> Result<()> {
        for _ in 0..count {
            inputbox
                .addInput(APP_ADDRESS, input_payload.as_bytes().into())
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
        let partition_provider = create_partition_provider(url)?;
        let mut read_epochs = Vec::new();
        while read_epochs.len() != count {
            // latest finalized block must be greater than 0
            let latest_finalized_block =
                std::cmp::max(1, partition_provider.latest_finalized_block().await?);

            read_epochs = epoch_reader
                .next(
                    None,
                    consensus_address,
                    0,
                    latest_finalized_block,
                    &partition_provider,
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
        input_reader: &EventReader<InputAdded>,
        count: usize,
    ) -> Result<Vec<InputAdded>> {
        let partition_provider = create_partition_provider(url)?;
        let mut read_inputs = Vec::new();
        while read_inputs.len() != count {
            // latest finalized block must be greater than 0
            let latest_finalized_block =
                std::cmp::max(1, partition_provider.latest_finalized_block().await?);

            read_inputs = input_reader
                .next(
                    Some(&APP_ADDRESS.into_word().into()),
                    inputbox_address,
                    0,
                    latest_finalized_block,
                    &partition_provider,
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
        state_manager: &Arc<SM>,
        epoch_number: u64,
        count: usize,
    ) -> Result<Vec<Vec<u8>>>
    where
        <SM as StateManager>::Error: Send + Sync + 'static,
    {
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
        let (anvil, provider, input_box_address, _, _) = spawn_anvil_and_provider();
        let inputbox = InputBox::new(input_box_address, &provider);

        let input_count_1 = 2;
        // Inputbox is deployed with 1 input already
        add_input(&inputbox, INPUT_PAYLOAD, input_count_1).await?;

        let input_reader = create_input_reader();
        let mut read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
            &input_reader,
            1 + input_count_1,
        )
        .await?;
        assert_eq!(read_inputs.len(), 1 + input_count_1);

        let received_payload =
            EvmAdvanceCall::abi_decode(read_inputs.last().unwrap().input.as_ref(), true)?;
        assert_eq!(received_payload.payload.as_ref(), INPUT_PAYLOAD.as_bytes());

        let input_count_2 = 3;
        add_input(&inputbox, INPUT_PAYLOAD2, input_count_2).await?;
        read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
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
        let (anvil, provider, _, consensus_address, initial_state) = spawn_anvil_and_provider();
        let daveconsensus = DaveConsensus::new(consensus_address, &provider);

        let epoch_reader = create_epoch_reader();
        let read_epochs =
            read_epochs_until_count(&anvil.endpoint(), daveconsensus.address(), &epoch_reader, 1)
                .await?;
        assert_eq!(read_epochs.len(), 1);
        assert_eq!(
            &read_epochs[0].initialMachineStateHash.abi_encode(),
            initial_state.slice()
        );

        drop(anvil);
        Ok(())
    }

    #[tokio::test]
    async fn test_blockchain_reader_aaa() -> Result<()> {
        let (anvil, provider, input_box_address, consensus_address, _) = spawn_anvil_and_provider();

        let inputbox = InputBox::new(input_box_address, &provider);
        let state_manager = Arc::new(PersistentStateAccess::new(
            Connection::open_in_memory().unwrap(),
        )?);

        // Note that inputbox is deployed with 1 input already
        // add inputs to epoch 0
        let input_count_1 = 2;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_1).await?;

        let daveconsensus = DaveConsensus::new(consensus_address, &provider);
        let blockchain_reader = BlockchainReader::new(
            state_manager.clone(),
            AddressBook {
                app: APP_ADDRESS,
                consensus: *daveconsensus.address(),
                input_box: *inputbox.address(),
            },
            provider.clone(),
            1,
        )
        .await?;

        let r = spawn(async move {
            blockchain_reader.start().await.unwrap();
        });

        read_inputs_from_db_until_count(&state_manager, 0, 1).await?;
        read_inputs_from_db_until_count(&state_manager, 1, input_count_1).await?;

        // add inputs to epoch 1
        let input_count_2 = 3;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_2).await?;
        read_inputs_from_db_until_count(&state_manager, 1, input_count_1 + input_count_2).await?;

        // add more inputs to epoch 1
        let input_count_3 = 3;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_3).await?;
        read_inputs_from_db_until_count(
            &state_manager,
            1,
            input_count_1 + input_count_2 + input_count_3,
        )
        .await?;

        drop(anvil);
        drop(r);
        Ok(())
    }
}
