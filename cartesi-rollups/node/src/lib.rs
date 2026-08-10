// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pub mod args;
pub mod blockchain_reader;
pub mod chain;
pub mod epoch_manager;
pub mod machine_runner;
pub mod provider;
pub mod storage;
pub mod sync;

// Shared primitives, folded in from the old common-rs crates: the
// node is their only consumer, and if it ever extracts to its own
// repo they travel inside it.
pub mod arithmetic;
pub mod kms;
pub mod merkle;

// The dispute engine: the spec-oracled geometry core (engine) and
// its consumers, the hero's react loop and the tournament layer.
pub mod engine;
pub mod hero;
pub mod tournament;

use args::NodeConfig;

use anyhow::{Result, anyhow};
use log::{error, info};
use std::sync::Arc;
use tokio::task::{JoinError, JoinHandle};

use crate::blockchain_reader::BlockchainReader;
use crate::chain::Chain;
use crate::epoch_manager::EpochManager;
use crate::machine_runner::MachineRunner;
use crate::sync::ShutdownSignal;
use crate::tournament::EthArenaSender;

/// Runs the node: one runtime, three workers, explicit spawns and
/// select arms - deliberately not a Worker abstraction, so each edit
/// stays obvious and local. Shutdown is a signal everyone observes
/// (see sync.rs); errors return through JoinHandles. The first exit,
/// or an interrupt, requests shutdown for the rest, and then EVERY
/// remaining handle is awaited - dropping one would detach its task
/// mid-drain, exactly the abrupt-write case crash recovery exists to
/// mop up. A worker that returns before shutdown was requested has
/// stopped unexpectedly: silence is a failure, not a success.
pub async fn run(config: NodeConfig, shutdown: ShutdownSignal) -> Result<()> {
    // Startup hygiene, before any worker spawns: sweep the scratch
    // a crash or an older node version left behind - settled epochs'
    // dispute work and the snapshot store's staging leftovers. Grows
    // into the sequencer-style ritual as more checks earn a place.
    {
        let mut storage = config.storage()?;
        storage.sweep_settled_epoch_scratch()?;
        storage.sweep_stale_staging()?;
    }

    // The machine runner is the blocking lane (machine execution +
    // SQLite): plain sync code on a blocking thread. The chain-facing
    // workers are async tasks. (The Hero's dispute loop still runs
    // inside the epoch manager's task and pins a runtime worker
    // during machine work; moving it to the blocking lane remains
    // future work.)
    let mut machine_runner: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::task::spawn_blocking(move || {
            let storage = params.storage()?;
            let mut machine_runner = MachineRunner::new(storage, params.sleep_duration)?;
            machine_runner.start(shutdown)?;
            Ok(())
        })
    };

    let mut blockchain_reader: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            let storage = params.storage()?;
            let chain = Chain::new(
                params.read_provider().await,
                params.long_block_range_error_codes.clone(),
            );
            let blockchain_reader =
                BlockchainReader::new(storage, params.address_book, params.sleep_duration);
            blockchain_reader.execution_loop(shutdown, chain).await
        })
    };

    let mut epoch_manager: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            // the epoch manager's own handle only reads; the Hero it
            // spawns opens its own writer
            let storage = params.storage_read_only()?;
            let read_provider = params.read_provider().await;
            let transaction_lane = params.transaction_lane(read_provider.clone()).await;
            let chain = Chain::new(
                read_provider.clone(),
                params.long_block_range_error_codes.clone(),
            );
            let arena_sender = EthArenaSender::new(read_provider);
            let epoch_manager = EpochManager::new(
                Arc::new(arena_sender),
                transaction_lane,
                params.address_book.consensus,
                params.signer_address,
                storage,
                params.sleep_duration,
            );
            epoch_manager.execution_loop(shutdown, chain).await?;
            Ok(())
        })
    };

    // Race the interrupt against every worker; biased so a pending
    // interrupt beats a ready worker exit.
    let mut finished = (false, false, false);
    let first_exit: Option<(&str, std::result::Result<Result<()>, JoinError>)> = tokio::select! {
        biased;
        _ = tokio::signal::ctrl_c() => {
            info!("interrupt received, starting shutdown");
            None
        }
        r = &mut machine_runner => { finished.0 = true; Some(("machine runner", r)) }
        r = &mut blockchain_reader => { finished.1 = true; Some(("blockchain reader", r)) }
        r = &mut epoch_manager => { finished.2 = true; Some(("epoch manager", r)) }
    };

    // Evaluated before the request below: a worker exit under an
    // externally requested shutdown is graceful, one before it is not.
    let failure =
        first_exit.and_then(|(name, joined)| worker_failure(name, joined, shutdown.is_requested()));

    shutdown.request();

    if !finished.0 {
        report_drained("machine runner", machine_runner.await);
    }
    if !finished.1 {
        report_drained("blockchain reader", blockchain_reader.await);
    }
    if !finished.2 {
        report_drained("epoch manager", epoch_manager.await);
    }

    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

fn worker_failure(
    name: &str,
    joined: std::result::Result<Result<()>, JoinError>,
    shutdown_requested: bool,
) -> Option<anyhow::Error> {
    match joined {
        Ok(Ok(())) if shutdown_requested => {
            info!("{name} shutdown gracefully");
            None
        }
        Ok(Ok(())) => Some(anyhow!("{name} stopped unexpectedly")),
        Ok(Err(e)) => {
            error!("{name} returned error: {e:#}");
            Some(e)
        }
        Err(join_error) => Some(anyhow!("{name} panicked: {join_error}")),
    }
}

fn report_drained(name: &str, joined: std::result::Result<Result<()>, JoinError>) {
    match joined {
        Ok(Ok(())) => info!("{name} shutdown gracefully"),
        Ok(Err(e)) => error!("{name} exited with error during shutdown: {e:#}"),
        Err(join_error) => error!("{name} panicked during shutdown: {join_error}"),
    }
}
