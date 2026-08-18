// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! `Storage` definition, connection lifecycle, and the transaction
//! closure helpers. Writer-role method clusters live in sibling files
//! (`ingest`, `advance`, `dispute`, `queries`), each adding its own
//! `impl Storage`.

use super::error::Result;
use super::rollups_machine::RollupsMachine;
use super::sql::migrations;
use crate::engine::{EngineConfig, Structure, config as sling_config};
use crate::merkle::Digest;
use alloy::primitives::Address;
use anyhow::Context;
use cartesi_machine::{format_emulator_version, machine::Machine};
use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// SQLite `synchronous` pragma for every connection. NORMAL under WAL
/// survives process crash but may lose the last commits on power
/// loss. That is enough here because the node is replay-tolerant by
/// design: every write is re-derivable from the chain and the machine,
/// and it externalizes nothing keyed on a commit. Revisit if a commit
/// ever gates an external effect.
const SYNCHRONOUS_PRAGMA: &str = "NORMAL";

/// Snapshot boundaries kept per epoch beyond the start and the
/// latest: every gap-th input. This is the disk-vs-replay knob for
/// dispute positioning; 1 keeps every boundary. It is also the
/// advance-batch size: one commit per gap worth of inputs.
pub const DEFAULT_SNAPSHOT_GAP_INPUTS: u64 = 64;

#[derive(Debug)]
pub struct Storage {
    pub(super) connection: Connection,
    pub(super) state_dir: PathBuf,
    pub(super) snapshot_gap_inputs: u64,
}

impl Storage {
    /// Process setup: creates the state directory, runs the
    /// migration, seeds the genesis watermark, stores and registers
    /// the template machine, and pins the engine configuration (which
    /// fails loudly on app or emulator drift against an existing
    /// state dir).
    pub fn migrate(
        state_dir: &Path,
        initial_machine_path: &Path,
        genesis_block_number: u64,
        app_address: Address,
    ) -> Result<Self> {
        create_directory_structure(state_dir)?;
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;

        let mut connection = open_writer_connection(&db_path(&state_dir))?;
        migrations::migrate_to_latest(&mut connection)?;

        let mut storage = Self {
            connection,
            state_dir,
            snapshot_gap_inputs: DEFAULT_SNAPSHOT_GAP_INPUTS,
        };

        storage.set_genesis(genesis_block_number)?;
        let template_hash = storage.set_initial_machine(initial_machine_path)?;

        sling_config::pin(
            &storage.connection,
            &EngineConfig {
                structure: Structure::PRODUCTION,
                app: app_address.as_slice().to_vec(),
                template_hash: Digest::from_digest(&template_hash).map_err(anyhow::Error::from)?,
                emulator_version: format_emulator_version(Machine::version()),
            },
        )?;

        Ok(storage)
    }

    /// A writer handle onto an already-migrated database. One
    /// connection per worker thread; SQLite's WAL plus the busy
    /// timeout arbitrate between them.
    pub fn new(state_dir: &Path) -> Result<Self> {
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;
        let connection = open_writer_connection(&db_path(&state_dir))?;

        Ok(Self {
            connection,
            state_dir,
            snapshot_gap_inputs: DEFAULT_SNAPSHOT_GAP_INPUTS,
        })
    }

    /// A read-only handle: the connection refuses writes outright and
    /// fails fast under write pressure rather than stalling a tick.
    pub fn open_read_only(state_dir: &Path) -> Result<Self> {
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;
        let connection = open_reader_connection(&db_path(&state_dir))?;

        Ok(Self {
            connection,
            state_dir,
            snapshot_gap_inputs: DEFAULT_SNAPSHOT_GAP_INPUTS,
        })
    }

    pub fn set_snapshot_gap_inputs(&mut self, gap: u64) {
        assert!(gap >= 1, "snapshot gap must be positive");
        self.snapshot_gap_inputs = gap;
    }

    pub fn snapshot_gap_inputs(&self) -> u64 {
        self.snapshot_gap_inputs
    }

    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    /// Runs `f` inside a Deferred transaction, committing on success.
    /// For reads: Deferred takes no write lock, so readers never
    /// block writers, and multi-statement reads still see one
    /// snapshot.
    pub(super) fn read<T>(&mut self, f: impl FnOnce(&Transaction) -> Result<T>) -> Result<T> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Deferred)
            .map_err(anyhow::Error::from)?;
        let out = f(&tx)?;
        tx.commit().map_err(anyhow::Error::from)?;
        Ok(out)
    }

    /// Runs `f` inside an Immediate transaction, committing on
    /// success. For mutations: Immediate takes the write lock at
    /// BEGIN, so a contending writer waits at the boundary of the
    /// domain operation instead of failing mid-transaction. On `Err`
    /// the transaction drops unsent - automatic rollback.
    ///
    /// Corruption tripwires escalate to panics here: the schema
    /// triggers (defense in depth BELOW the Rust-side checks) surface
    /// as ordinary rusqlite errors, and the workers' tick loops retry
    /// every error forever - a nondeterminism abort must instead
    /// reach the node's loud exit path (lib.rs worker_failure). The
    /// fragments are the triggers' own messages, pinned by the
    /// discipline tests.
    pub(super) fn write<T>(&mut self, f: impl FnOnce(&Transaction) -> Result<T>) -> Result<T> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(anyhow::Error::from)?;
        let out = escalate_tripwires(f(&tx))?;
        tx.commit().map_err(anyhow::Error::from)?;
        Ok(out)
    }

    fn set_genesis(&mut self, block_number: u64) -> Result<()> {
        self.write(|tx| super::ingest::raise_watermark_in(tx, block_number))
    }

    /// Stores the initial machine into the content-addressed store
    /// and registers it as both the epoch-0 boundary and the template
    /// (filesystem first, then one transaction for the rows).
    fn set_initial_machine(
        &mut self,
        source_machine_path: &Path,
    ) -> Result<cartesi_machine::types::Hash> {
        assert!(
            source_machine_path.is_dir(),
            "machine path `{}` must be an existing directory",
            source_machine_path.display()
        );

        // Hash through a private load (cheap: the image ships valid
        // hash sidecars), then clone the image into the store - no
        // 500 MB re-serialization through machine memory. Cross-
        // filesystem imports degrade to a sparse copy inside the
        // clone.
        let state_hash = RollupsMachine::new(source_machine_path, 0, 0)?.state_hash()?;
        let working = self
            .checkout(source_machine_path)
            .map_err(anyhow::Error::from)?;
        let dest_machine_path = self
            .commit_clone(working, &state_hash)
            .map_err(anyhow::Error::from)?;

        self.write(|tx| {
            super::snapshots::insert_snapshot_in(tx, 0, 0, &state_hash, &dest_machine_path)?;
            super::snapshots::insert_template_machine_in(tx, &state_hash)?;
            Ok(())
        })?;

        Ok(state_hash)
    }

    /// The per-epoch scratch directory (dispute logs and artifacts);
    /// filesystem lifecycle, not SQL.
    pub fn epoch_directory(&mut self, epoch_number: u64) -> Result<PathBuf> {
        create_epoch_dir(&self.state_dir, epoch_number)
    }
}

/// Writer connections: WAL, enforced foreign keys, NORMAL sync, and a
/// generous busy timeout (machine work happens between transactions,
/// never inside one, so writers only contend for row-commit bursts).
/// Escalates the schema triggers' corruption tripwires into panics.
/// The Rust-side checks already panic at their sites; the triggers
/// beneath them (defense in depth, and the only check raw writers
/// meet) abort with these exact message fragments - pinned by the
/// discipline tests - and would otherwise flow into the workers'
/// retry-forever tick loops as ordinary errors. Discipline refusals
/// that are part of an API's contract (append-only, validate_next)
/// stay errors: callers legitimately observe those.
fn escalate_tripwires<T>(result: Result<T>) -> Result<T> {
    if let Err(e) = &result {
        let text = format!("{e:#}");
        for fragment in [
            "nondeterminism or corruption",
            "node cache collision",
            "corruption or version drift",
            "disagrees with its stored row",
        ] {
            assert!(
                !text.contains(fragment),
                "storage tripwire fired: {text} (invariant violation, not retryable)"
            );
        }
    }
    result
}

fn open_writer_connection(db_path: &Path) -> Result<Connection> {
    let connection = Connection::open(db_path).map_err(anyhow::Error::from)?;
    configure_writer_pragmas(&connection)?;
    Ok(connection)
}

fn configure_writer_pragmas(connection: &Connection) -> Result<()> {
    // Foreign keys are per-connection in SQLite and default OFF in
    // stock builds; without this pragma the schema's ON DELETE
    // RESTRICT protections are declarative only.
    connection
        .pragma_update(None, "foreign_keys", "ON")
        .map_err(anyhow::Error::from)?;
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .map_err(anyhow::Error::from)?;
    connection
        .pragma_update(None, "synchronous", SYNCHRONOUS_PRAGMA)
        .map_err(anyhow::Error::from)?;
    connection
        .busy_timeout(std::time::Duration::from_secs(10))
        .map_err(anyhow::Error::from)?;
    Ok(())
}

fn open_reader_connection(db_path: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(anyhow::Error::from)?;
    connection
        .pragma_update(None, "query_only", "ON")
        .map_err(anyhow::Error::from)?;
    connection
        .busy_timeout(std::time::Duration::from_millis(100))
        .map_err(anyhow::Error::from)?;
    Ok(connection)
}

//
// State directory layout
//

pub fn db_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("db.sqlite3")
}

pub fn snapshots_path(state_dir: &Path) -> PathBuf {
    state_dir.to_owned().join("snapshots")
}

pub fn create_empty_state_dir_if_needed(state_dir: &Path) -> Result<()> {
    fs::create_dir_all(state_dir).with_context(|| format!("creating `{}`", state_dir.display()))?;
    Ok(())
}

fn create_directory_structure(state_dir: &Path) -> Result<()> {
    create_empty_state_dir_if_needed(state_dir)?;

    let snapshots_path = snapshots_path(state_dir);
    fs::create_dir_all(&snapshots_path)
        .with_context(|| format!("creating `{}`", &snapshots_path.display()))?;

    Ok(())
}

fn epoch_dir(state_dir: &Path, epoch_number: u64) -> PathBuf {
    state_dir.join(epoch_number.to_string())
}

pub(super) fn create_epoch_dir(state_dir: &Path, epoch_number: u64) -> Result<PathBuf> {
    let path = epoch_dir(state_dir, epoch_number);
    fs::create_dir_all(&path).with_context(|| format!("creating `{}`", &path.display()))?;

    Ok(path)
}
