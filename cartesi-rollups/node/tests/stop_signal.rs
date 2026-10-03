// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The node's stop signals, in their own test binary: listening installs
//! process-wide handlers that stay for the life of the process, and in the
//! lib's unit-test binary they would swallow Ctrl-C and CI's SIGTERM for
//! every later test.

use cartesi_rollups_prt_node::sync::StopSignals;
use std::time::Duration;

/// One test raising both signals in turn: a signal reaches every listener
/// in the process, so parallel tests would read each other's. Each is
/// raised before the first poll, which pins that listening starts at
/// construction; without a handler the raise kills this binary.
#[tokio::test]
async fn sigterm_and_sigint_resolve_the_stop_signals() {
    for (signal, name) in [(libc::SIGTERM, "SIGTERM"), (libc::SIGINT, "SIGINT")] {
        let mut stops = StopSignals::listen().unwrap();
        assert_eq!(unsafe { libc::raise(signal) }, 0);
        let received = tokio::time::timeout(Duration::from_secs(5), stops.next())
            .await
            .unwrap_or_else(|_| panic!("{name} did not resolve the listener"));
        assert_eq!(received, name);
    }
}
