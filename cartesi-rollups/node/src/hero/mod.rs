//! The honest validator's dispute actor.
//!
//! One accepted chain observation is projected into the local semantic path,
//! planned without provider or machine access, fulfilled into one owned arena
//! action, and dispatched once. Cleanup planning remains actor-neutral and is
//! considered only when the Hero has no action.

pub mod action;
mod actor;
pub mod context;
pub mod error;
pub mod gc_planner;
pub mod planner;

pub use actor::{Hero, HeroTick, TournamentResult};

/// Runs local machine work (commitment builds, proofs) from the dispute's
/// async task without pinning a runtime worker: on the multi-threaded
/// runtime the worker hands its queued tasks to a replacement first, so the
/// chain-facing tasks keep running through a leaf build of many minutes.
/// The Hero itself still waits, since its next action depends on the
/// result. A current-thread runtime (unit tests) cannot hand off and runs
/// the work inline.
pub(crate) fn machine_work<R>(work: impl FnOnce() -> R) -> R {
    use tokio::runtime::{Handle, RuntimeFlavor};
    match Handle::try_current().map(|handle| handle.runtime_flavor()) {
        Ok(RuntimeFlavor::MultiThread) => tokio::task::block_in_place(work),
        _ => work(),
    }
}

#[cfg(test)]
mod tests {
    use super::machine_work;
    use std::{sync::mpsc, time::Duration};

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn machine_work_frees_the_runtime_worker() {
        // Spawned from the only worker, the other task queues behind it: it
        // runs during the blocking wait only if the worker was handed off.
        let waited = tokio::spawn(async {
            let (sent, received) = mpsc::channel();
            let other = tokio::spawn(async move { sent.send(()).unwrap() });
            let ran = machine_work(|| received.recv_timeout(Duration::from_secs(5)));
            other.await.unwrap();
            ran
        });
        assert!(waited.await.unwrap().is_ok(), "the queued task starved");
    }
}
