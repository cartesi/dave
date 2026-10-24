// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

// Pub: what the binaries and integration tests import, and
// blockchain_reader, whose AddressBook is a NodeConfig field. The rest
// stays crate-private so rustc reports its dead code.
pub mod args;
pub mod blockchain_reader;
pub mod chain;
mod epoch_manager;
mod escalation;
pub mod fatal;
pub mod machine_runner;
pub mod provider;
pub mod storage;
pub mod sync;

// Shared primitives, folded in from the old common-rs crates: the
// node is their only consumer, and if it ever extracts to its own
// repo they travel inside it.
pub mod arithmetic;
mod kms;
pub mod merkle;

// The dispute engine: the spec-oracled geometry core (engine) and
// its consumers, the hero's react loop and the tournament layer.
pub mod engine;
mod hero;
mod tournament;

#[cfg(test)]
mod harness;

use args::NodeConfig;

use anyhow::{Context, Result, anyhow};
use log::{error, info};
use tokio::task::{JoinError, JoinHandle};

use crate::blockchain_reader::BlockchainReader;
use crate::chain::Chain;
use crate::epoch_manager::EpochManager;
use crate::fatal::Panicked;
use crate::machine_runner::MachineRunner;
use crate::sync::{ShutdownSignal, StopSignals};

/// Runs the node: one runtime, three workers, explicit spawns and
/// select arms - deliberately not a Worker abstraction, so each edit
/// stays obvious and local. Shutdown is a signal everyone observes
/// (see sync.rs); errors return through JoinHandles. The first exit,
/// or a stop signal (SIGINT or SIGTERM), requests shutdown for the
/// rest, and then EVERY remaining handle is awaited - dropping one
/// would detach its task mid-drain, exactly the abrupt-write case
/// crash recovery exists to mop up. A worker that returns before
/// shutdown was requested has stopped unexpectedly: silence is a
/// failure, not a success.
pub async fn run(config: NodeConfig) -> Result<()> {
    // Listening first, so a stop during the spawns is caught rather than
    // taking the signal's default action. Storage::initialize already
    // swept the staging leftovers a crash left behind.
    let mut stop_signals = StopSignals::listen().context("failed to listen for stop signals")?;
    let shutdown = ShutdownSignal::default();

    // The machine runner is the blocking lane (machine execution +
    // SQLite): plain sync code on a blocking thread. The chain-facing
    // workers are async tasks. The Hero's dispute loop runs inside the
    // epoch manager's task and hands its runtime worker off before
    // machine work (hero::machine_work), so a long commitment build
    // stalls only the manager itself.
    let mut machine_runner: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::task::spawn_blocking(move || {
            let storage = params.storage()?;
            let mut machine_runner = MachineRunner::new(
                storage,
                params.snapshot_gap_inputs,
                params.sleep_duration,
                shutdown,
            )?;
            machine_runner.start()?;
            Ok(())
        })
    };

    let mut blockchain_reader: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            let storage = params.storage()?;
            let chain = Chain::new(params.read_provider()?);
            let blockchain_reader =
                BlockchainReader::new(storage, params.address_book, params.sleep_duration);
            blockchain_reader.execution_loop(shutdown, chain).await
        })
    };

    let mut epoch_manager: JoinHandle<Result<()>> = {
        let params = config.clone();
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            // The manager owns the durable epoch-completion cursor.
            let storage = params.storage()?;
            let read_provider = params.read_provider()?;
            let transaction_lane = params.transaction_lane(read_provider.clone())?;
            let chain = Chain::new(read_provider);
            let epoch_manager = EpochManager::new(
                transaction_lane,
                params.address_book.consensus,
                params.address_book.app,
                params.signer_address,
                storage,
                params.sleep_duration,
                shutdown,
            );
            epoch_manager.execution_loop(chain).await?;
            Ok(())
        })
    };

    // Race the stop signals against every worker; biased so a pending
    // signal beats a ready worker exit.
    let mut finished = (false, false, false);
    let first_exit: Option<(&str, std::result::Result<Result<()>, JoinError>)> = tokio::select! {
        biased;
        name = stop_signals.next() => {
            info!("{name} received, starting shutdown");
            None
        }
        r = &mut machine_runner => { finished.0 = true; Some(("machine runner", r)) }
        r = &mut blockchain_reader => { finished.1 = true; Some(("blockchain reader", r)) }
        r = &mut epoch_manager => { finished.2 = true; Some(("epoch manager", r)) }
    };

    let failure = first_exit.map(|(name, joined)| worker_failure(name, joined));
    // Logged now, not only at exit: the drain can take an input's run.
    if let Some(e) = &failure {
        error!("{e:#}; stopping the other workers");
    }

    shutdown.request();

    // A stop signal during the drain (a second one, or the first after a
    // worker exit) exits at once: as crash-safe as SIGKILL, and a person
    // at a terminal need not find another way to kill the process. It keeps
    // the failure's exit status.
    let code = failure.as_ref().map_or(1, fatal::exit_code);
    tokio::spawn(async move {
        let name = stop_signals.next().await;
        error!("{name} received during shutdown, exiting without draining");
        std::process::exit(code.into());
    });

    let mut failure = failure;
    for (done, name, handle) in [
        (finished.0, "machine runner", machine_runner),
        (finished.1, "blockchain reader", blockchain_reader),
        (finished.2, "epoch manager", epoch_manager),
    ] {
        if done {
            continue;
        }
        failure = merged_failure(failure, drained_failure(name, handle.await));
    }

    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// The first worker exit, which comes before any shutdown request, so even
/// a clean return is a failure.
fn worker_failure(name: &str, joined: std::result::Result<Result<()>, JoinError>) -> anyhow::Error {
    match joined {
        Ok(Ok(())) => anyhow!("{name} stopped unexpectedly"),
        Ok(Err(e)) => e.context(format!("{name} failed")),
        Err(join_error) => Panicked(format!("{name} panicked: {join_error}")).into(),
    }
}

/// A failure during the drain is the run's failure too, unless an earlier
/// one already is, which keeps its exit status; a stop signal does not make
/// a failed drain graceful.
fn merged_failure(
    failure: Option<anyhow::Error>,
    drained: Option<anyhow::Error>,
) -> Option<anyhow::Error> {
    match (failure, drained) {
        (Some(failure), Some(later)) => {
            error!("{later:#}");
            Some(failure)
        }
        (failure, drained) => failure.or(drained),
    }
}

fn drained_failure(
    name: &str,
    joined: std::result::Result<Result<()>, JoinError>,
) -> Option<anyhow::Error> {
    match joined {
        Ok(Ok(())) => {
            info!("{name} shutdown gracefully");
            None
        }
        Ok(Err(e)) => Some(e.context(format!("{name} failed during shutdown"))),
        Err(join_error) => {
            Some(Panicked(format!("{name} panicked during shutdown: {join_error}")).into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fatal::{Fatal, exit_code};

    fn terminal() -> std::result::Result<Result<()>, JoinError> {
        Ok(Err(Fatal::terminal("diverged").into()))
    }

    async fn panicked() -> std::result::Result<Result<()>, JoinError> {
        tokio::spawn(async { panic!("worker bug") }).await
    }

    /// The exit status operators configure their supervisor against.
    #[tokio::test]
    async fn the_run_keeps_the_status_of_its_first_failure() {
        // A stop signal, then a worker failing during the drain: not graceful.
        let drained = merged_failure(None, drained_failure("epoch manager", terminal()));
        assert_eq!(exit_code(&drained.unwrap()), 30);

        // A worker failure keeps its status over a later drain failure.
        let first = Some(worker_failure("blockchain reader", terminal()));
        let later = drained_failure("machine runner", panicked().await);
        assert_eq!(exit_code(&merged_failure(first, later).unwrap()), 30);

        // A panic during the drain exits as a panic.
        let drained = merged_failure(None, drained_failure("machine runner", panicked().await));
        assert_eq!(exit_code(&drained.unwrap()), 101);

        assert!(merged_failure(None, drained_failure("epoch manager", Ok(Ok(())))).is_none());
    }
}

#[cfg(test)]
mod test_machine;
