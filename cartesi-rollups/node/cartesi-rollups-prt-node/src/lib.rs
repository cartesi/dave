// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod args;
pub mod provider;

use args::PRTConfig;

use log::{error, info};
use std::{sync::Arc, thread};
use tokio::sync::Mutex;

use cartesi_prt_core::tournament::EthArenaSender;
use rollups_blockchain_reader::BlockchainReader;
use rollups_epoch_manager::EpochManager;
use rollups_machine_runner::MachineRunner;
use rollups_state_manager::sync::Watch;

macro_rules! notify_all {
    ($worker:literal, $watch:expr, $res:expr) => {{
        match $res {
            Ok(Ok(())) => {
                info!("{} shutdown gracefully", $worker);
            }
            Ok(Err(e)) => {
                error!("{} returned error: {e}", $worker);
                info!("Starting shutdown");
                $watch.notify(Arc::new(anyhow::anyhow!(e)));
            }
            Err(e) => {
                error!("{} panicked: {e:?}", $worker);
                info!("Starting shutdown");
                $watch.notify(Arc::new(anyhow::anyhow!(format!("{e:?}"))));
            }
        }
    }};
}

fn create_runtime(service: &str) -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap_or_else(|e| panic!("`{}` runtime build failure: {e}", service))
}

pub fn create_blockchain_reader_task(
    watch: Watch,
    parameters: &PRTConfig,
) -> thread::JoinHandle<()> {
    let params = parameters.clone();
    let inner_watch = watch.clone();

    thread::Builder::new()
        .name("blockchain-reader".into())
        .spawn(move || {
            let res = std::panic::catch_unwind(|| {
                let rt = create_runtime("BlockchainReader");

                rt.block_on(async move {
                    let state_manager = params.state_access().unwrap();
                    let blockchain_reader = BlockchainReader::new(
                        state_manager,
                        params.address_book,
                        params.sleep_duration,
                        params.long_block_range_error_codes.clone(),
                    );

                    blockchain_reader
                        .execution_loop(inner_watch, params.provider().await)
                        .await
                })
                .inspect_err(|e| error!("{e}"))
            });

            notify_all!("Blockchain reader", watch, res);
        })
        .expect("failed to spawn blockchain reader thread")
}

pub fn create_epoch_manager_task(watch: Watch, parameters: &PRTConfig) -> thread::JoinHandle<()> {
    let params = parameters.clone();
    let inner_watch = watch.clone();

    thread::Builder::new()
        .name("epoch-manager".into())
        .spawn(move || {
            let res = std::panic::catch_unwind(|| {
                let rt = create_runtime("EpochManager");
                rt.block_on(async move {
                    let state_manager = params.state_access().unwrap();
                    let provider = params.provider().await;
                    let arena_sender = EthArenaSender::new(provider.clone())
                        .expect("could not create arena sender");

                    let epoch_manager = EpochManager::new(
                        Arc::new(Mutex::new(arena_sender)),
                        params.address_book.consensus,
                        state_manager,
                        params.sleep_duration,
                        params.long_block_range_error_codes.clone(),
                    );

                    epoch_manager.execution_loop(inner_watch, provider).await
                })
                .inspect_err(|e| error!("{e}"))
            });

            notify_all!("Epoch manager", watch, res);
        })
        .expect("failed to spawn epoch manager thread")
}

pub fn create_machine_runner_task(watch: Watch, parameters: &PRTConfig) -> thread::JoinHandle<()> {
    let params = parameters.clone();

    thread::Builder::new()
        .name("machine-runner".into())
        .spawn(move || {
            let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let state_manager = params.state_access().unwrap();

                let mut machine_runner = MachineRunner::new(state_manager, params.sleep_duration)
                    .inspect_err(|e| error!("{e}"))
                    .unwrap();

                machine_runner
                    .start(watch.clone())
                    .inspect_err(|e| error!("{e}"))
            }));

            notify_all!("Machine runner", watch, res);
        })
        .expect("failed to spawn machine runner thread")
}
