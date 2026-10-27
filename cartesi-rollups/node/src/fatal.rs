// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Failures a restart cannot fix, and the exit status the process reports
//! for each. The numbers follow the sequencer's exit-code contract: 0 a
//! requested stop, 1 any other error (restart with backoff), 2 a usage error
//! (clap), 30 terminal (do not restart: an operator must act), 40 rebuild the
//! data directory.
//!
//! A panic exits 101, Rust's own status, and asks for a restart with backoff
//! and a page. It marks an invariant violation, which a restart cannot make
//! worse (nothing is written before validation, and recovery is a replay)
//! and may clear while a dispute clock runs; a deterministic one loops, and
//! the page fires. The sequencer, whose diagnosed faults cannot heal, aborts
//! there instead: the different status is a different meaning.

use std::fmt::Display;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FatalKind {
    /// A flag, the seed image, the deployment or the settled chain
    /// disagrees with this node, or finalized foreclosure has left no
    /// dispute defense or bond recovery to do.
    Terminal,
    /// The data directory belongs to another store format, commitment semantics,
    /// emulator, consensus or tournament geometry.
    Rebuild,
}

/// A failure no restart fixes. Raise it at the root of an error chain;
/// context added above it keeps it visible to [`Fatal::of`].
#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct Fatal {
    kind: FatalKind,
    message: String,
}

impl Fatal {
    pub fn terminal(message: impl Display) -> Self {
        Self {
            kind: FatalKind::Terminal,
            message: message.to_string(),
        }
    }

    pub fn rebuild(message: impl Display) -> Self {
        Self {
            kind: FatalKind::Rebuild,
            message: message.to_string(),
        }
    }

    /// The fatal cause anywhere in `error`'s chain.
    pub fn of(error: &anyhow::Error) -> Option<FatalKind> {
        error
            .chain()
            .find_map(|cause| cause.downcast_ref::<Fatal>())
            .map(|fatal| fatal.kind)
    }
}

/// A worker panicked. The panic hook logged its message when it happened.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct Panicked(pub String);

/// The process exit status for a failed run.
pub fn exit_code(error: &anyhow::Error) -> u8 {
    match Fatal::of(error) {
        Some(FatalKind::Terminal) => 30,
        Some(FatalKind::Rebuild) => 40,
        None if error.chain().any(|cause| cause.is::<Panicked>()) => 101,
        None => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Context;

    #[test]
    fn a_fatal_cause_survives_context() {
        let error = anyhow::Error::new(Fatal::rebuild("schema mismatch"))
            .context("could not open the data directory");
        assert_eq!(Fatal::of(&error), Some(FatalKind::Rebuild));
        assert_eq!(exit_code(&error), 40);
        assert_eq!(
            format!("{error:#}"),
            "could not open the data directory: schema mismatch"
        );

        let error = Err::<(), _>(Fatal::terminal("wrong template"))
            .context("startup")
            .unwrap_err();
        assert_eq!(exit_code(&error), 30);
    }

    #[test]
    fn other_failures_retry_and_panics_page() {
        assert_eq!(exit_code(&anyhow::anyhow!("rpc down")), 1);
        let error = anyhow::Error::new(Panicked("epoch manager panicked".into()));
        assert_eq!(exit_code(&error), 101);
    }
}
