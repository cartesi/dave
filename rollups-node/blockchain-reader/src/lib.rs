// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
mod error;

use crate::error::{ProviderErrors, Result};

use async_recursion::async_recursion;
use error::BlockchainReaderError;
use ethers::abi::RawLog;
use std::str::FromStr;
use std::{sync::Arc, time::Duration};

use ethers::contract::EthEvent;
use ethers::prelude::{Http, ProviderError};
use ethers::providers::{Middleware, Provider};
use ethers::types::{Address, BlockNumber, Filter, Topic};

use cartesi_rollups_contracts::input_box::InputAddedFilter as NewInputAddedFilter;
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

// TODO: use actual event type from the rollups_contract crate
/// this is the old event format,
/// it should be replaced by the actual `InputAddedFilter` after it's deployed and published
#[derive(EthEvent)]
#[ethevent(name = "InputAdded", abi = "InputAdded(address,uint256,address,bytes)")]
pub struct InputAddedFilter {
    #[ethevent(indexed)]
    pub app_contract: ::ethers::core::types::Address,
    #[ethevent(indexed)]
    pub index: ::ethers::core::types::U256,
    pub address: ethers::core::types::Address,
    pub input: ::ethers::core::types::Bytes,
}

/// this is a placeholder for the non-existing epoch event
#[derive(EthEvent)]
#[ethevent(name = "EpochSealed", abi = "EpochSealed(uint256,uint256)")]
pub struct EpochSealedFilter {
    #[ethevent(indexed)]
    pub epoch_index: ::ethers::core::types::U256,
    #[ethevent(indexed)]
    pub input_count: ::ethers::core::types::U256,
}

pub struct AddressBook {
    consensus: Address,
    input_box: Address,
    topic1_of_input_box: Topic,
}

pub struct BlockchainReader<SM: StateManager> {
    state_manager: Arc<SM>,
    address_book: AddressBook,
    provider: PartitionProvider,
    input_reader: EventReader<InputAddedFilter>,
    epoch_reader: EventReader<EpochSealedFilter>,
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
        sleep_duration: Duration,
    ) -> std::result::Result<Self, <Http as FromStr>::Err> {
        let partition_provider = PartitionProvider::new(provider_url)?;

        Ok(Self {
            state_manager,
            address_book,
            provider: partition_provider,
            input_reader: EventReader::<InputAddedFilter>::new(),
            epoch_reader: EventReader::<EpochSealedFilter>::new(),
            sleep_duration,
        })
    }

    pub async fn start(&mut self) -> Result<(), SM> {
        // read from DB the block of the most recent processed
        let mut prev_block = self
            .state_manager
            .latest_processed_block()
            .map_err(|e| BlockchainReaderError::StateManagerError(e))?;

        loop {
            let current_block = self.provider.latest_finalized_block().await?;
            self.advance(prev_block, current_block).await?;
            prev_block = current_block;

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
        // read new inputs from blockchain
        let inputs: Vec<Input> = self
            .input_reader
            .next(
                Some(&self.address_book.topic1_of_input_box),
                &self.address_book.input_box,
                prev_block,
                current_block,
                &self.provider,
            )
            .await?
            .iter()
            .map(|e| Input {
                // TODO: use correct values
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0,
                },
                data: e.input.to_vec(),
            })
            .collect();
        // read epochs from blockchain
        let epochs: Vec<Epoch> = self
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
                // TODO: use correct values
                epoch_number: e.epoch_index.as_u64(),
                input_count: 0,
            })
            .collect();

        Ok((inputs, epochs))
    }
}

pub struct EventReader<E: EthEvent> {
    __phantom: std::marker::PhantomData<E>,
}

impl<E: EthEvent> EventReader<E> {
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
    ) -> std::result::Result<Vec<E>, ProviderErrors> {
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
    inner: Provider<Http>,
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
impl PartitionProvider {
    fn new(provider_url: &str) -> std::result::Result<Self, <Http as FromStr>::Err> {
        Ok(PartitionProvider {
            inner: Provider::<Http>::try_from(provider_url)?,
        })
    }

    async fn get_events<E: EthEvent>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> std::result::Result<Vec<E>, Vec<ProviderError>> {
        self.get_events_rec(topic1, read_from, start_block, end_block)
            .await
    }

    #[async_recursion]
    async fn get_events_rec<E: EthEvent>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> std::result::Result<Vec<E>, Vec<ProviderError>> {
        // TODO: partition log queries if range too large
        let filter = {
            let mut f = Filter::new()
                .from_block(start_block)
                .to_block(end_block)
                .address(*read_from)
                .event(&E::abi_signature());

            if let Some(t) = topic1 {
                f = f.topic1(t.clone());
            }

            f
        };

        let res = {
            // Make number of concurrent fetches bounded.
            self.inner.get_logs(&filter).await
        };

        match res {
            Ok(l) => {
                let logs = l
                    .into_iter()
                    .map(RawLog::from)
                    .map(|x| E::decode_log(&x).unwrap())
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
            .get_block(BlockNumber::Finalized)
            .await
            .map_err(|e| ProviderErrors(vec![e]))?
            .expect("block is empty")
            .number
            .expect("block number is empty")
            .as_u64();

        Ok(block_number)
    }

    fn should_retry_with_partition(err: &ProviderError) -> bool {
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
    let app = Address::from_str("0x0974cc873df893b302f6be7ecf4f9d4b1a15c366")?.into();
    let infura_key = std::env::var("INFURA_KEY").expect("INFURA_KEY is not set");

    let partition_provider =
        PartitionProvider::new(format!("https://mainnet.infura.io/v3/{}", infura_key).as_ref())?;
    let reader = EventReader::<InputAddedFilter>::new();

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
