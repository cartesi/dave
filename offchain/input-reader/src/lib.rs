// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use async_recursion::async_recursion;
use ethers::abi::RawLog;
use tokio::sync::Semaphore;

// use cartesi_rollups_contracts::input_box::input_box::InputAddedFilter;
use ethers::contract::EthEvent;
use ethers::prelude::{Http, ProviderError};
use ethers::providers::{Middleware, Provider};
use ethers::types::{Address, BlockNumber, Filter, H160, U64};

/// `OldInputAddedFilter` is the old event format,
/// it should be replaced by the actual `InputAddedFilter` after it's deployed and published
#[derive(
    Clone,
    ::ethers::contract::EthEvent,
    ::ethers::contract::EthDisplay,
    serde::Serialize,
    serde::Deserialize,
    Default,
    Debug,
    PartialEq,
    Eq,
    Hash,
)]
#[ethevent(name = "InputAdded", abi = "InputAdded(address,uint256,address,bytes)")]
pub struct OldInputAddedFilter {
    #[ethevent(indexed)]
    pub app_contract: ::ethers::core::types::Address,
    #[ethevent(indexed)]
    pub index: ::ethers::core::types::U256,
    pub address: ethers::core::types::Address,
    pub input: ::ethers::core::types::Bytes,
}

struct PartitionProvider {
    provider: Provider<Http>,
    semaphore: Semaphore,
    input_box: Address,
    app: H160,
}

#[derive(Debug)]
struct ProviderErr(Vec<String>);

impl std::fmt::Display for ProviderErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Partition error: {:?}", self.0)
    }
}

impl std::error::Error for ProviderErr {}

pub struct InputReader {
    last_finalized: U64,
    provider: PartitionProvider,
}

impl InputReader {
    pub fn new(
        last_finalized_opt: Option<U64>,
        input_box: Address,
        provider_url: &str,
        concurrency_opt: Option<usize>,
        app: H160,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            last_finalized: last_finalized_opt.unwrap_or_default(),
            provider: PartitionProvider {
                input_box,
                provider: Provider::<Http>::try_from(provider_url)?,
                semaphore: Semaphore::new(concurrency_opt.unwrap_or_default()),
                app,
            },
        })
    }

    pub async fn next(&mut self) -> Result<Vec<OldInputAddedFilter>, Box<dyn std::error::Error>> {
        let block_opt = self
            .provider
            .provider
            .get_block(BlockNumber::Finalized)
            .await
            .map_err(|e| ProviderErr(vec![e.to_string()]))?;

        if let Some(block) = block_opt {
            if let Some(current_finalized) = block.number {
                println!("Last finalized block at number: {:?}", self.last_finalized);
                println!("Current finalized block at number: {:?}", current_finalized);

                if current_finalized > self.last_finalized {
                    let logs = self
                        .provider
                        .get_events(self.last_finalized.as_u64(), current_finalized.as_u64())
                        .await
                        .map_err(|err_arr| {
                            ProviderErr(err_arr.into_iter().map(|e| e.to_string()).collect())
                        })?;

                    // update last finalized block
                    self.last_finalized = current_finalized;
                    return Ok(logs);
                }
            }
        }

        Ok(vec![])
    }
}

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
impl PartitionProvider {
    async fn get_events(
        &self,
        start_block: u64,
        end_block: u64,
    ) -> Result<Vec<OldInputAddedFilter>, Vec<ProviderError>> {
        self.get_events_rec(start_block, end_block).await
    }

    #[async_recursion]
    async fn get_events_rec(
        &self,
        start_block: u64,
        end_block: u64,
    ) -> Result<Vec<OldInputAddedFilter>, Vec<ProviderError>> {
        // TODO: partition log queries if range too large
        let filter = Filter::new()
            .from_block(start_block)
            .to_block(end_block)
            .address(self.input_box)
            .event(&OldInputAddedFilter::abi_signature())
            .topic1(self.app);

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
                    .map(|x| OldInputAddedFilter::decode_log(&x))
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

                    let first_fut = self.get_events_rec(start_block, middle);
                    let second_fut = self.get_events_rec(middle + 1, end_block);

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

async fn test_input_reader() -> Result<(), Box<dyn std::error::Error>> {
    use std::str::FromStr;

    let genesis: U64 = U64::from(17784733);
    let input_box = Address::from_str("0x59b22D57D4f067708AB0c00552767405926dc768")?;
    let app = Address::from_str("0x0974cc873df893b302f6be7ecf4f9d4b1a15c366")?;
    let infura_key = std::env::var("INFURA_KEY").expect("INFURA_KEY is not set");

    let mut reader = InputReader::new(
        Some(genesis),
        input_box,
        format!("https://mainnet.infura.io/v3/{}", infura_key).as_ref(),
        Some(5),
        app,
    )?;

    let res: Vec<_> = reader.next().await?;

    // input box from mainnet shouldn't be empty
    assert!(!res.is_empty(), "input box shouldn't be empty");

    Ok(())
}
