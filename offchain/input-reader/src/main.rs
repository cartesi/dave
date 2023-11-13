// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use async_recursion::async_recursion;
use tokio::sync::Semaphore;

use ethers::prelude::{Http, ProviderError};
use ethers::providers::{Middleware, Provider};
use ethers::types::{Address, BlockNumber, Filter, Log, U64};

use std::str::FromStr;
use std::{thread, time};

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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Hello, world!");

    // TODO: get from configuration
    let genesis: U64 = U64::from(17784733);
    let mut last_finalized: U64 = genesis;
    let interval = time::Duration::from_secs(10);

    // TODO: get from configuration
    let input_box = Address::from_str("0x59b22D57D4f067708AB0c00552767405926dc768")?;
    let provider = Provider::<Http>::try_from(
        "https://mainnet.infura.io/v3/6d58afadb5a94a978b232aabc243a82f",
    )?;
    let semaphore = Semaphore::new(5);

    let partition_provider = PartitionProvider {
        input_box,
        provider,
        semaphore,
    };

    loop {
        let block_opt = partition_provider
            .provider
            .get_block(BlockNumber::Finalized)
            .await
            .map_err(|e| ProviderErr(vec![e.to_string()]))?;

        if let Some(block) = block_opt {
            if let Some(current_finalized) = block.number {
                println!("Last finalized block at number: {:?}", last_finalized);
                println!("Current finalized block at number: {:?}", current_finalized);

                if current_finalized > last_finalized {
                    let logs = partition_provider
                        .get_events(last_finalized.as_u64(), current_finalized.as_u64())
                        .await
                        .map_err(|err_arr| {
                            ProviderErr(err_arr.into_iter().map(|e| e.to_string()).collect())
                        })?;

                    if logs.len() > 0 {
                        println!("Inputs arrived: {:?}", logs);
                    } else {
                        println!("No input submitted!")
                    }

                    // update last finalized block
                    last_finalized = current_finalized;
                }
            }
        }
        thread::sleep(interval);
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
