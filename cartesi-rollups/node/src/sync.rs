// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Shutdown as a primitive, not an error channel: anyone may request
//! shutdown, workers observe it, and that is the whole contract.
//! Worker errors do NOT travel through here - they return through
//! their JoinHandles, and the runtime loop in lib.rs turns the first
//! exit into a shutdown request for everyone else. (The predecessor,
//! Watch, carried the first error to every worker through a condvar;
//! that conflation is what this replaces.)

use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;
use tokio::sync::Notify;

#[derive(Debug, Clone, Default)]
pub struct ShutdownSignal {
    inner: Arc<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    requested: AtomicBool,
    // async waiters (worker select loops)
    notify: Notify,
    // blocking waiters (the machine runner's sleep)
    mutex: Mutex<()>,
    condvar: Condvar,
}

impl ShutdownSignal {
    pub fn request(&self) {
        self.inner.requested.store(true, Ordering::SeqCst);
        self.inner.notify.notify_waiters();
        let _guard = self.inner.mutex.lock().unwrap();
        self.inner.condvar.notify_all();
    }

    pub fn is_requested(&self) -> bool {
        self.inner.requested.load(Ordering::SeqCst)
    }

    /// Resolves when shutdown is requested; immediately if it already
    /// was. Cancel-safe: made for `select!` against the worker's tick
    /// sleep.
    pub async fn requested(&self) {
        let mut notified = std::pin::pin!(self.inner.notify.notified());
        // enable() is the registration point (creating the future is
        // not); registering before the flag check closes the race
        // where a request lands between check and first poll and its
        // notify_waiters reaches no one. One round suffices: the flag
        // is set before the wake and never clears.
        notified.as_mut().enable();
        if self.is_requested() {
            return;
        }
        notified.await;
    }

    /// Blocking sleep that a shutdown request cuts short. Returns
    /// whether shutdown was requested.
    pub fn wait_timeout(&self, duration: Duration) -> bool {
        let guard = self.inner.mutex.lock().unwrap();
        let _unused = self
            .inner
            .condvar
            .wait_timeout_while(guard, duration, |()| !self.is_requested())
            .unwrap();
        self.is_requested()
    }
}

#[cfg(test)]
mod tests {
    use super::ShutdownSignal;
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn fresh_signal_times_out() {
        let s = ShutdownSignal::default();
        assert!(!s.wait_timeout(Duration::from_millis(10)));
        assert!(!s.is_requested());
    }

    #[test]
    fn request_cuts_blocking_wait_short() {
        let s = ShutdownSignal::default();
        let s2 = s.clone();

        let handle = thread::spawn(move || {
            let t0 = Instant::now();
            assert!(s2.wait_timeout(Duration::from_secs(5)));
            assert!(t0.elapsed() < Duration::from_millis(500));
        });

        thread::sleep(Duration::from_millis(50));
        s.request();
        handle.join().unwrap();
        assert!(s.is_requested());
    }

    #[test]
    fn request_is_idempotent_and_sticky() {
        let s = ShutdownSignal::default();
        s.request();
        s.request();
        assert!(s.is_requested());
        // an already-requested signal does not sleep
        let t0 = Instant::now();
        assert!(s.wait_timeout(Duration::from_secs(5)));
        assert!(t0.elapsed() < Duration::from_millis(500));
    }

    #[tokio::test]
    async fn async_waiter_wakes_on_request() {
        let s = ShutdownSignal::default();
        let s2 = s.clone();

        let waiter = tokio::spawn(async move { s2.requested().await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        s.request();
        tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("waiter wakes")
            .unwrap();
    }

    #[tokio::test]
    async fn async_waiter_resolves_immediately_when_already_requested() {
        let s = ShutdownSignal::default();
        s.request();
        tokio::time::timeout(Duration::from_millis(100), s.requested())
            .await
            .expect("resolves without waiting");
    }
}
