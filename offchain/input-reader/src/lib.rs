// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::Result;
use async_recursion::async_recursion;
use tokio::sync::Semaphore;

use ethers::prelude::{Http, ProviderError};
use ethers::providers::{Middleware, Provider};
use ethers::types::{Address, BlockNumber, Filter, Log, U64};

struct PartitionProvider {
    provider: Provider<Http>,
    semaphore: Semaphore,
    input_box: Address,
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
    ) -> Result<Self> {
        Ok(Self {
            last_finalized: last_finalized_opt.unwrap_or_default(),
            provider: PartitionProvider {
                input_box,
                provider: Provider::<Http>::try_from(provider_url)?,
                semaphore: Semaphore::new(concurrency_opt.unwrap_or_default()),
            },
        })
    }

    pub async fn next(&mut self) -> Result<Vec<Log>> {
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
    ) -> Result<Vec<Log>, Vec<ProviderError>> {
        self.get_events_rec(start_block, end_block).await
    }

    #[async_recursion]
    async fn get_events_rec(
        &self,
        start_block: u64,
        end_block: u64,
    ) -> Result<Vec<Log>, Vec<ProviderError>> {
        // TODO: partition log queries if range too large
        let filter = Filter::new()
            .from_block(start_block)
            .to_block(end_block)
            .address(self.input_box);

        let res = {
            // Make number of concurrent fetches bounded.
            let _permit = self.semaphore.acquire().await;
            self.provider.get_logs(&filter).await
        };

        match res {
            Ok(l) => Ok(l),
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

async fn test_input_reader() -> Result<()> {
    use std::str::FromStr;

    let genesis: U64 = U64::from(17784733);
    let input_box = Address::from_str("0x59b22D57D4f067708AB0c00552767405926dc768")?;
    let infura_key = std::env::var("INFURA_KEY").expect("INFURA_KEY is not set");

    let mut reader = InputReader::new(
        Some(genesis),
        input_box,
        format!("https://mainnet.infura.io/v3/{}", infura_key).as_ref(),
        Some(5),
    )?;

    let res: Vec<Log> = reader.next().await?;

    // input box from mainnet shouldn't be empty
    assert!(!res.is_empty(), "input box shouldn't be empty");

    Ok(())
}
