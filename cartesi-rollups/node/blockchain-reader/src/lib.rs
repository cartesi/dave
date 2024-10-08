// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;

use crate::error::{ProviderErrors, Result};

use alloy::{
    contract::{Error, Event},
    eips::BlockNumberOrTag::Finalized,
    providers::{
        network::primitives::BlockTransactionsKind, Provider, ProviderBuilder, RootProvider,
    },
    sol_types::{private::Address, SolEvent},
    transports::http::{reqwest::Url, Client, Http},
};
use alloy_rpc_types_eth::Topic;
use async_recursion::async_recursion;
use clap::Parser;
use error::BlockchainReaderError;
use num_traits::cast::ToPrimitive;
use std::{
    marker::{Send, Sync},
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use cartesi_dave_contracts::daveconsensus::DaveConsensus::EpochSealed;
use cartesi_rollups_contracts::inputbox::InputBox::InputAdded;
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

#[derive(Debug, Clone, Parser)]
#[command(name = "cartesi_rollups_config")]
#[command(about = "Addresses of Cartesi Rollups")]
pub struct AddressBook {
    /// address of app
    #[arg(long, env)]
    app: Address,
    /// address of Dave consensus
    #[arg(long, env)]
    pub consensus: Address,
    /// address of input box
    #[arg(long, env)]
    input_box: Address,
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
    pub fn new(
        state_manager: Arc<SM>,
        address_book: AddressBook,
        provider_url: &str,
        sleep_duration: u64,
    ) -> Result<Self, SM> {
        let partition_provider = PartitionProvider::new(provider_url)
            .map_err(|e| BlockchainReaderError::ParseError(e))?;
        // read from DB the block of the most recent processed
        let prev_block = state_manager
            .latest_processed_block()
            .map_err(|e| BlockchainReaderError::StateManagerError(e))?;

        Ok(Self {
            state_manager,
            address_book,
            prev_block,
            provider: partition_provider,
            input_reader: EventReader::<InputAdded>::new(),
            epoch_reader: EventReader::<EpochSealed>::new(),
            sleep_duration: Duration::from_secs(sleep_duration),
        })
    }

    pub async fn start(&mut self) -> Result<(), SM> {
        loop {
            let current_block = self.provider.latest_finalized_block().await?;
            self.advance(self.prev_block, current_block).await?;
            self.prev_block = current_block;

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
            .map_err(|e| BlockchainReaderError::StateManagerError(e))?;

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

        // read inputs from blockchain
        let inputs = self
            .collect_inputs(
                prev_block,
                current_block,
                sealed_epochs.iter().collect::<Vec<&Epoch>>().into_iter(),
            )
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
            .map(|e| Epoch {
                epoch_number: e
                    .0
                    .epochNumber
                    .to_u64()
                    .expect("fail to convert epoch number"),
                epoch_boundary: e
                    .0
                    .blockNumberUpperBound
                    .to_u64()
                    .expect("fail to convert epoch boundary"),
                root_tournament: e.0.tournament.to_string(),
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
        let input_events = self
            .input_reader
            .next(
                Some(&self.address_book.app.into_word().into()),
                &self.address_book.input_box,
                prev_block,
                current_block,
                &self.provider,
            )
            .await?;

        let last_input = self
            .state_manager
            .last_input()
            .map_err(|e| BlockchainReaderError::StateManagerError(e))?;

        let (mut next_input_index_in_epoch, mut last_epoch_number) = {
            match last_input {
                // continue inserting inputs from where it was left
                Some(input) => (input.input_index_in_epoch + 1, input.epoch_number),
                // first ever input for the application
                None => (0, 0),
            }
        };

        let mut inputs = vec![];
        let mut input_events_iter = input_events.iter();
        for epoch in sealed_epochs_iter {
            // iterate through newly sealed epochs, fill in the inputs accordingly
            let inputs_of_epoch = self
                .construct_input_ids(
                    epoch.epoch_number,
                    epoch.epoch_boundary,
                    &mut next_input_index_in_epoch,
                    &mut input_events_iter,
                )
                .await;

            inputs.extend(inputs_of_epoch);
            last_epoch_number = epoch.epoch_number + 1;
        }

        // all remaining inputs belong to an epoch that's not sealed yet
        let inputs_of_epoch = self
            .construct_input_ids(
                last_epoch_number,
                u64::MAX,
                &mut next_input_index_in_epoch,
                &mut input_events_iter,
            )
            .await;

        inputs.extend(inputs_of_epoch);

        Ok(inputs)
    }

    async fn construct_input_ids(
        &self,
        epoch_number: u64,
        epoch_boundary: u64,
        next_input_index_in_epoch: &mut u64,
        input_events_iter: &mut impl Iterator<Item = &(InputAdded, u64)>,
    ) -> Vec<Input> {
        let mut inputs = vec![];

        while input_events_iter
            .peekable()
            .peek()
            .expect("fail to get peek next input")
            .1
            < epoch_boundary
        {
            let input = Input {
                id: InputId {
                    epoch_number,
                    input_index_in_epoch: *next_input_index_in_epoch,
                },
                data: input_events_iter.next().unwrap().0.input.to_vec(),
            };

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
    pub fn new() -> Self {
        Self {
            __phantom: std::marker::PhantomData,
        }
    }

    async fn next(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        prev_finalized: u64,
        current_finalized: u64,
        provider: &PartitionProvider,
    ) -> std::result::Result<Vec<(E, u64)>, ProviderErrors> {
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
            .map_err(|err_arr| ProviderErrors(err_arr))?;

        return Ok(logs);
    }
}

struct PartitionProvider {
    inner: RootProvider<Http<Client>>,
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
impl PartitionProvider {
    fn new(provider_url: &str) -> std::result::Result<Self, <Url as FromStr>::Err> {
        let url = provider_url.parse()?;
        let provider = ProviderBuilder::new().on_http(url);
        Ok(PartitionProvider { inner: provider })
    }

    async fn get_events<E: SolEvent + Send + Sync>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> std::result::Result<Vec<(E, u64)>, Vec<Error>> {
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
    ) -> std::result::Result<Vec<(E, u64)>, Vec<Error>> {
        // TODO: partition log queries if range too large
        let event = {
            let mut e = Event::new_sol(&self.inner, read_from)
                .from_block(start_block)
                .to_block(end_block)
                .event(&E::SIGNATURE);

            if let Some(t) = topic1 {
                e = e.topic1(t.clone());
            }

            e
        };

        match event.query().await {
            Ok(l) => {
                let logs = l
                    .into_iter()
                    .map(|x| {
                        (
                            x.0,
                            x.1.block_number
                                .expect("fail to get block number from event"),
                        )
                    })
                    .collect();

                Ok(logs)
            }
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
            .get_block(Finalized.into(), BlockTransactionsKind::Hashes)
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

#[tokio::test]

async fn test_input_reader() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let genesis = 17784733;
    let input_box = Address::from_str("0x59b22D57D4f067708AB0c00552767405926dc768")?;
    let app = Address::from_str("0x0974cc873df893b302f6be7ecf4f9d4b1a15c366")?
        .into_word()
        .into();
    let infura_key = std::env::var("INFURA_KEY").expect("INFURA_KEY is not set");

    let partition_provider =
        PartitionProvider::new(format!("https://mainnet.infura.io/v3/{}", infura_key).as_ref())?;
    let reader = EventReader::<InputAdded>::new();

    let res = reader
        .next(
            Some(&app),
            &input_box,
            genesis,
            partition_provider.latest_finalized_block().await?,
            &partition_provider,
        )
        .await?;

    // input box from mainnet shouldn't be empty
    assert!(!res.is_empty(), "input box shouldn't be empty");

    Ok(())
}
