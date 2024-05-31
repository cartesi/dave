// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use anyhow::Result;
use async_recursion::async_recursion;
use cartesi_rollups_contracts::inputs;
use ethers::abi::RawLog;
use std::{str::FromStr, sync::Arc, thread::sleep, time::Duration};
use tokio::sync::Semaphore;

use ethers::contract::EthEvent;
use ethers::prelude::{Http, ProviderError};
use ethers::providers::{Middleware, Provider};
use ethers::types::{Address, BlockNumber, Filter, Topic};

use cartesi_rollups_contracts::input_box::InputAddedFilter;
use rollups_state_manager::{Epoch, Input, InputId, StateManager};

pub struct BlockchainReader {
    last_finalized: u64,
    consensus: Address,
    input_box: Address,
    provider: PartitionProvider,
    sleep_duration: Duration,
}

impl BlockchainReader {
    pub fn new(
        app_genesis: u64,
        consensus: Address,
        input_box: Address,
        provider_url: &str,
        concurrency_opt: Option<usize>,
        sleep_duration: Duration,
    ) -> Result<Self> {
        let mut partition_provider = PartitionProvider::new(provider_url)?;
        if let Some(c) = concurrency_opt {
            partition_provider.set_concurrency(c);
        }

        Ok(Self {
            consensus,
            input_box,
            last_finalized: app_genesis,
            provider: partition_provider,
            sleep_duration,
        })
    }
    pub async fn start<SM: StateManager>(&mut self, s: Arc<SM>) -> Result<()>
    where
        <SM as StateManager>::Error: Send + Sync + 'static,
    {
        let app = Address::from_str("0x0974cc873df893b302f6be7ecf4f9d4b1a15c366")?;

        // read from DB the block of the most recent processed
        let mut prev_block = {
            let latest_processed_block = s.latest_processed_block()?;
            if latest_processed_block >= self.last_finalized {
                latest_processed_block
            } else {
                self.last_finalized
            }
        };

        let inputs_reader = EventReader::<InputAddedFilter>::new(app.into(), self.input_box)?;
        // TODO: change this to NewEpochFilter
        let epoch_reader = EventReader::<InputAddedFilter>::new(app.into(), self.consensus)?;

        loop {
            let current_block = self
                .provider
                .latest_finalized_block()
                .await?
                .expect("fail to get latest block");

            // read new inputs from blockchain
            let input_events = inputs_reader
                .next(prev_block, current_block, &self.provider)
                .await?;
            // read epochs from blockchain
            let epoch_events = epoch_reader
                .next(prev_block, current_block, &self.provider)
                .await?;

            // TODO: all state updates should be be atomic
            s.insert_consensus_data(current_block, input_events, epoch_events);

            prev_block = current_block;
            sleep(self.sleep_duration);
        }

        Ok(())
    }
}

#[derive(Debug)]
struct ProviderErr(Vec<String>);

impl std::fmt::Display for ProviderErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Partition error: {:?}", self.0)
    }
}

impl std::error::Error for ProviderErr {}

pub struct EventReader<E: EthEvent> {
    topic1: Topic,
    read_from: Address,
    __phantom: std::marker::PhantomData<E>,
}

impl<E: EthEvent> EventReader<E> {
    pub fn new(topic1: Topic, read_from: Address) -> Result<Self> {
        let reader = Self {
            topic1: topic1.into(),
            read_from,
            __phantom: std::marker::PhantomData,
        };

        Ok(reader)
    }

    // returns (last_finalized_block, vector of events)
    async fn next(
        &self,
        prev_finalized: u64,
        current_finalized: u64,
        provider: &PartitionProvider,
    ) -> Result<Vec<E>> {
        if current_finalized > prev_finalized {
            let logs = provider
                .get_events(
                    &self.topic1,
                    &self.read_from,
                    prev_finalized,
                    current_finalized,
                )
                .await
                .map_err(|err_arr| {
                    ProviderErr(err_arr.into_iter().map(|e| e.to_string()).collect())
                })?;

            return Ok(logs);
        }

        // Should we return error here?
        Ok(vec![])
    }
}

struct PartitionProvider {
    provider: Provider<Http>,
    semaphore: Semaphore,
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
impl PartitionProvider {
    fn new(provider_url: &str) -> Result<Self> {
        Ok(PartitionProvider {
            provider: Provider::<Http>::try_from(provider_url)?,
            semaphore: Semaphore::new(4),
        })
    }

    fn set_concurrency(&mut self, concurrency: usize) {
        self.semaphore = Semaphore::new(concurrency);
    }

    async fn get_events<E: EthEvent>(
        &self,
        topic1: &Topic,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> Result<Vec<E>, Vec<ProviderError>> {
        self.get_events_rec(topic1, read_from, start_block, end_block)
            .await
    }

    #[async_recursion]
    async fn get_events_rec<E: EthEvent>(
        &self,
        topic1: &Topic,
        read_from: &Address,
        start_block: u64,
        end_block: u64,
    ) -> Result<Vec<E>, Vec<ProviderError>> {
        // TODO: partition log queries if range too large
        let filter = Filter::new()
            .from_block(start_block)
            .to_block(end_block)
            .address(*read_from)
            .event(&E::abi_signature())
            .topic1(topic1.clone());

        let res = {
            // Make number of concurrent fetches bounded.
            let _permit = self.semaphore.acquire().await;
            self.provider.get_logs(&filter).await
        };

        match res {
            Ok(l) => {
                let logs = l
                    .into_iter()
                    .map(RawLog::from)
                    .map(|x| E::decode_log(&x))
                    .collect::<Result<Vec<_>, _>>()
                    .unwrap();

                Ok(logs)
            }
            Err(e) => {
                if Self::should_retry_with_partition(&e) {
                    let middle = {
                        let blocks = 1 + end_block - start_block;
                        let half = blocks / 2;
                        start_block + half - 1
                    };

                    let first_fut = self.get_events_rec(topic1, read_from, start_block, middle);
                    let second_fut = self.get_events_rec(topic1, read_from, middle + 1, end_block);

                    let (first_res, second_res) = futures::join!(first_fut, second_fut);

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

    async fn latest_finalized_block(&self) -> Result<Option<u64>> {
        let block_opt = self
            .provider
            .get_block(BlockNumber::Finalized)
            .await
            .map_err(|e| ProviderErr(vec![e.to_string()]))?;

        Ok(block_opt.map(|b| b.number.expect("fail to get block number").as_u64()))
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

async fn test_input_reader() -> Result<()> {
    /// `OldInputAddedFilter` is the old event format,
    /// it should be replaced by the actual `InputAddedFilter` after it's deployed and published
    #[derive(EthEvent)]
    #[ethevent(name = "InputAdded", abi = "InputAdded(address,uint256,address,bytes)")]
    pub struct OldInputAddedFilter {
        #[ethevent(indexed)]
        pub app_contract: ::ethers::core::types::Address,
        #[ethevent(indexed)]
        pub index: ::ethers::core::types::U256,
        pub address: ethers::core::types::Address,
        pub input: ::ethers::core::types::Bytes,
    }

    let genesis = 17784733;
    let input_box = Address::from_str("0x59b22D57D4f067708AB0c00552767405926dc768")?;
    let app = Address::from_str("0x0974cc873df893b302f6be7ecf4f9d4b1a15c366")?;
    let infura_key = std::env::var("INFURA_KEY").expect("INFURA_KEY is not set");

    let mut partition_provider =
        PartitionProvider::new(format!("https://mainnet.infura.io/v3/{}", infura_key).as_ref())?;
    partition_provider.set_concurrency(5);

    let reader = EventReader::<OldInputAddedFilter>::new(app.into(), input_box)?;

    let res = reader
        .next(
            genesis,
            partition_provider
                .latest_finalized_block()
                .await?
                .expect("fail to get latest block"),
            &partition_provider,
        )
        .await?;

    // input box from mainnet shouldn't be empty
    assert!(!res.is_empty(), "input box shouldn't be empty");

    Ok(())
}
