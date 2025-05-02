// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::{
    ops::ControlFlow,
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};

#[derive(Debug, Clone)]
pub struct Watch(Arc<(Mutex<ControlFlow<Arc<anyhow::Error>>>, Condvar)>);

impl Default for Watch {
    fn default() -> Self {
        Self(Arc::new((
            Mutex::new(ControlFlow::Continue(())),
            Condvar::new(),
        )))
    }
}

impl Watch {
    pub fn wait(&self, duration: Duration) -> ControlFlow<Arc<anyhow::Error>> {
        let (mutex, cvar) = &*self.0;
        let (flow, _) = cvar
            .wait_timeout_while(mutex.lock().unwrap(), duration, |notification| {
                matches!(notification, ControlFlow::Continue(()))
            })
            .unwrap();

        match &*flow {
            ControlFlow::Break(e) => ControlFlow::Break(e.clone()),
            _ => ControlFlow::Continue(()), // timed‑out OR spurious
        }
    }

    pub fn notify(&self, err: Arc<anyhow::Error>) {
        let (mutex, cvar) = &*self.0;
        let mut flow = mutex.lock().unwrap();
        if matches!(*flow, ControlFlow::Continue(_)) {
            *flow = ControlFlow::Break(err);
            cvar.notify_all();
        }
    }

    pub fn err(&self) -> Option<Arc<anyhow::Error>> {
        let (mutex, _) = &*self.0;
        let flow = mutex.lock().unwrap();

        match &*flow {
            ControlFlow::Continue(_) => None,
            ControlFlow::Break(e) => Some(e.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Watch;
    use anyhow::anyhow;
    use std::{
        ops::ControlFlow,
        sync::Arc,
        thread,
        time::{Duration, Instant},
    };

    /// Helper: create a dummy error wrapped in `Arc`.
    fn test_err(msg: &str) -> Arc<anyhow::Error> {
        Arc::new(anyhow!(msg.to_owned()))
    }

    #[test]
    fn fresh_watch_times_out() {
        let w = Watch::default();

        // Wait for a very small timeout; should *not* break.
        let res = w.wait(Duration::from_millis(10));
        assert!(matches!(res, ControlFlow::Continue(_)));
        assert!(w.err().is_none());
    }

    #[test]
    fn notify_breaks_waiter_and_sets_error() {
        let w = Watch::default();
        let w2 = w.clone();

        let handle = thread::spawn(move || {
            // Large timeout so only notify can wake us early.
            let res = w2.wait(Duration::from_secs(5));
            assert!(matches!(res, ControlFlow::Break(_)));
        });

        // Give the spawned thread a moment to park on the condvar.
        thread::sleep(Duration::from_millis(50));

        let err = test_err("boom");
        w.notify(err.clone());

        handle.join().unwrap();

        // Main thread sees the same error.
        assert!(Arc::ptr_eq(&w.err().unwrap(), &err));
    }

    #[test]
    fn first_error_is_preserved() {
        let w = Watch::default();

        let first = test_err("first");
        let second = test_err("second");

        w.notify(first.clone());
        w.notify(second);

        let stored = w.err().unwrap();
        assert!(Arc::ptr_eq(&stored, &first));
    }

    #[test]
    fn multiple_waiters_all_break() {
        let w = Watch::default();
        let mut handles = Vec::new();

        for _ in 0..4 {
            let w_clone = w.clone();
            handles.push(thread::spawn(move || {
                let res = w_clone.wait(Duration::from_secs(5));
                assert!(matches!(res, ControlFlow::Break(_)));
            }));
        }

        // Let all threads block.
        thread::sleep(Duration::from_millis(50));

        // Time how fast they wake up (should be << 5 s).
        let t0 = Instant::now();
        w.notify(test_err("stop"));
        for h in handles {
            h.join().unwrap();
        }
        assert!(t0.elapsed() < Duration::from_millis(500));
    }
}
