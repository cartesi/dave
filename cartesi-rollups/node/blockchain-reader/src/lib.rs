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
use clap::Parser;
use find_contract_creation::find_contract_creation_block;
use log::{debug, info, trace};
use num_traits::cast::ToPrimitive;
use rollups_state_manager::sync::Watch;
use std::ops::ControlFlow;
use std::{
    env::var,
    fmt,
    iter::Peekable,
    marker::{Send, Sync},
    str::FromStr,
    time::Duration,
};

use cartesi_dave_contracts::daveconsensus::DaveConsensus::{self, EpochSealed};
use cartesi_dave_merkle::Digest;
use cartesi_rollups_contracts::{application::Application, inputbox::InputBox::InputAdded};
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

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
        if self.app == Address::ZERO {
            self.consensus = Address::from_str(
                var("CONSENSUS")
                    .expect("fail to load consensus address")
                    .as_str(),
            )
            .expect("fail to parse consensus address");
        } else {
            let application = Application::new(self.app, provider);
            self.consensus = application
                .getOutputsMerkleRootValidator()
                .call()
                .await
                .expect("fail to query consensus address")
                ._0;
        }
        let consensus_contract = DaveConsensus::new(self.consensus, provider);
        let consensus_created_block = find_contract_creation_block(provider, self.consensus)
            .await
            .expect("fail to get consensus creation block");

        debug!(
            "consensus created {} at {}",
            consensus_created_block, self.consensus
        );

        self.input_box = consensus_contract
            .getInputBox()
            .call()
            .await
            .expect("fail to query input box address")
            ._0;

        let sealed_epochs = consensus_contract
            .EpochSealed_filter()
            .address(self.consensus)
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
        sleep_duration: u64,
    ) -> Self {
        Self {
            state_manager,
            address_book,
            provider,
            input_reader: EventReader::<InputAdded>::default(),
            epoch_reader: EventReader::<EpochSealed>::default(),
            sleep_duration: Duration::from_secs(sleep_duration),
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
    use cartesi_rollups_contracts::{
        inputbox::InputBox::{self, InputAdded},
        inputs::Inputs::EvmAdvanceCall,
    };
    use rollups_state_manager::persistent_state_access::PersistentStateAccess;

    use tokio::time::{Duration, sleep};

    type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
    const APP_ADDRESS: Address = Address::ZERO;
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

    async fn add_input(
        inputbox: &InputBox::InputBoxInstance<(), DynProvider>,
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
                    Some(&APP_ADDRESS.into_word().into()),
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
        let (anvil, provider, input_box_address, _, _) = spawn_anvil_and_provider();
        let inputbox = InputBox::new(input_box_address, provider.clone());

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
    async fn test_blockchain_reader() -> Result<()> {
        let (anvil, provider, input_box_address, consensus_address, _) = spawn_anvil_and_provider();

        let inputbox = InputBox::new(input_box_address, provider.clone());

        let dir = tempfile::TempDir::new()?;
        let db_path = dir.path().join("my.db");
        PersistentStateAccess::migrate(&db_path)?;
        let mut state_manager = PersistentStateAccess::new(&db_path)?;

        // Note that inputbox is deployed with 1 input already
        // add inputs to epoch 0
        let input_count_1 = 2;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_1).await?;

        let watch = Watch::default();

        let watch_0 = watch.clone();
        let r = thread::spawn(move || {
            let address_book = AddressBook {
                app: APP_ADDRESS,
                consensus: consensus_address,
                input_box: input_box_address,
            };

            let blockchain_reader = BlockchainReader::new(
                PersistentStateAccess::new(&db_path).unwrap(),
                provider,
                address_book,
                1,
            );

            blockchain_reader.start(watch_0).unwrap();
        });

        read_inputs_from_db_until_count(&mut state_manager, 0, 1).await?;
        read_inputs_from_db_until_count(&mut state_manager, 1, input_count_1).await?;

        // add inputs ttest_blockchain_readero epoch 1
        let input_count_2 = 3;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_2).await?;
        read_inputs_from_db_until_count(&mut state_manager, 1, input_count_1 + input_count_2)
            .await?;

        // add more inputs to epoch 1
        let input_count_3 = 3;
        add_input(&inputbox, INPUT_PAYLOAD, input_count_3).await?;
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
