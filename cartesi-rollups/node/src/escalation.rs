// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The node's one paging rule. A failure that would cost a dispute if it
//! persisted logs WARN while it lasts and ERROR once it has lasted
//! [`PAGE_AFTER`]: a transient provider blip never pages, and a page means
//! the condition outlived a response window.

use log::Level;
use std::time::{Duration, Instant};

/// G, the response window: every action is budgeted to land within it
/// (`Deployment.s.sol`'s `_getInclusionBudget`, 5 minutes on every chain),
/// and a due response later than that draws on the dispute's
/// non-rechargeable censorship budget C. A failure shorter than G costs no
/// clock; a longer one is worth an operator's attention.
///
/// Hardcoded: the node pins the deployed table, but not the chain's block
/// time, so it cannot turn the table's block budgets into wall-clock time.
/// Revisit if a deployment's G departs from 5 minutes (configure the block
/// time, or read it from the chain registration).
pub const PAGE_AFTER: Duration = Duration::from_secs(5 * 60);

/// How long one failure condition has held.
#[derive(Debug, Default)]
pub struct Persistence {
    since: Option<Instant>,
}

impl Persistence {
    /// Records that the condition holds, and returns the level to log it at.
    pub fn failed(&mut self) -> Level {
        self.failed_at(Instant::now())
    }

    fn failed_at(&mut self, now: Instant) -> Level {
        let since = *self.since.get_or_insert(now);
        if now.saturating_duration_since(since) >= PAGE_AFTER {
            Level::Error
        } else {
            Level::Warn
        }
    }

    pub fn cleared(&mut self) {
        self.since = None;
    }

    /// How long the condition has held, in whole minutes, for log lines.
    pub fn minutes(&self) -> u64 {
        self.since.map_or(0, |since| since.elapsed().as_secs() / 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_pages_once_it_outlasts_the_response_window() {
        let start = Instant::now();
        let mut failing = Persistence::default();
        assert_eq!(failing.failed_at(start), Level::Warn);
        assert_eq!(failing.failed_at(start + PAGE_AFTER / 2), Level::Warn);
        assert_eq!(failing.failed_at(start + PAGE_AFTER), Level::Error);

        failing.cleared();
        let later = start + 2 * PAGE_AFTER;
        assert_eq!(
            failing.failed_at(later),
            Level::Warn,
            "a recovery restarts the clock"
        );
        assert_eq!(failing.failed_at(later + PAGE_AFTER), Level::Error);
    }
}
