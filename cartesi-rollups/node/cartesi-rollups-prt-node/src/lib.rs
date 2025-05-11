// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod args;
pub mod provider;

use args::PRTConfig;

use log::{error, info};
use std::{sync::Arc, thread};

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

pub fn create_blockchain_reader_task(
    watch: Watch,
    parameters: &PRTConfig,
) -> thread::JoinHandle<()> {
    let params = parameters.clone();

    thread::spawn(move || {
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let state_manager = params.state_access().unwrap();

            let blockchain_reader = BlockchainReader::new(
                state_manager,
                params.provider,
                params.address_book,
                params.sleep_duration,
            );

            blockchain_reader
                .start(watch.clone())
                .inspect_err(|e| error!("{e}"))
        }));

        notify_all!("Blockchain reader", watch, res);
    })
}

pub fn create_epoch_manager_task(watch: Watch, parameters: &PRTConfig) -> thread::JoinHandle<()> {
    let params = parameters.clone();

    thread::spawn(move || {
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let arena_sender = EthArenaSender::new(params.provider.clone())
                .expect("could not create arena sender");

            let state_manager = params.state_access().unwrap();

            let epoch_manager = EpochManager::new(
                arena_sender,
                params.provider,
                params.address_book.consensus,
                state_manager,
                params.sleep_duration,
            );

            epoch_manager
                .start(watch.clone())
                .inspect_err(|e| error!("{e}"))
        }));

        notify_all!("Epoch manager", watch, res);
    })
}

pub fn create_machine_runner_task(watch: Watch, parameters: &PRTConfig) -> thread::JoinHandle<()> {
    let params = parameters.clone();

    thread::spawn(move || {
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let state_manager = params.state_access().unwrap();

            // `MachineRunner` has to be constructed in side the spawn block since `machine::Machine`` doesn't implement `Send`
            let mut machine_runner = MachineRunner::new(state_manager, params.sleep_duration)
                .inspect_err(|e| error!("{e}"))
                .unwrap();

            machine_runner
                .start(watch.clone())
                .inspect_err(|e| error!("{e}"))
        }));

        notify_all!("Machine runner", watch, res);
    })
}
