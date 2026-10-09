// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! `Storage` definition, connection lifecycle, and the transaction
//! closure helpers. Writer-role method clusters live in sibling files
//! (`ingest`, `advance`, `dispute`, `queries`), each adding its own
//! `impl Storage`.

use super::error::Result;
use super::sql::schema;
use crate::engine::{EngineConfig, Structure, TournamentGeometry, config as sling_config};
use crate::merkle::Digest;
use alloy::primitives::Address;
use anyhow::{Context, ensure};
use cartesi_machine::{
    config::runtime::RuntimeConfig, format_emulator_version, machine::Machine, types::Hash,
};
use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// SQLite `synchronous` pragma for every connection. FULL, because a
/// commit gates an external effect: snapshot directories are removed
/// once the commit that stops referencing them lands, and under NORMAL
/// a power loss can undo that commit while the removals persist,
/// leaving rows that name missing directories. The node commits a few
/// times per tick, so the extra fsync is free.
const SYNCHRONOUS_PRAGMA: &str = "FULL";

/// Snapshot boundaries kept per epoch beyond the start and the
/// latest: every gap-th input. This is the disk-vs-replay knob for
/// dispute positioning; 1 keeps every boundary. It is also the
/// advance-batch size: one commit per gap worth of inputs.
pub const DEFAULT_SNAPSHOT_GAP_INPUTS: u64 = 64;

/// Non-numeric, so the scratch sweep never takes it for an epoch.
const LOCK_FILE: &str = "node.lock";

/// One node process owns a state directory: a second one would sweep the
/// first's working clones and publish into and collect the same snapshot
/// store. Startup takes this lock before the first write and holds it for the
/// life of the process; the kernel releases it on any exit, so a crash leaves
/// nothing stale. It does not make the signer exclusive: two directories may
/// still share one key.
#[derive(Debug)]
pub struct StateDirLock {
    _file: fs::File,
}

impl StateDirLock {
    pub fn acquire(state_dir: &Path) -> Result<Self> {
        create_empty_state_dir_if_needed(state_dir)?;
        let path = state_dir.join(LOCK_FILE);
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .with_context(|| format!("opening `{}`", path.display()))?;
        match file.try_lock() {
            Ok(()) => Ok(Self { _file: file }),
            Err(fs::TryLockError::WouldBlock) => Err(anyhow::anyhow!(
                "data directory `{}` is in use by another node process",
                state_dir.display()
            )
            .into()),
            // Refuse rather than run unlocked: the lock is the only guard.
            Err(fs::TryLockError::Error(error)) => Err(anyhow::Error::from(error)
                .context(format!(
                    "cannot lock data directory `{}` (does its filesystem support file locks?)",
                    state_dir.display()
                ))
                .into()),
        }
    }
}

#[derive(Debug)]
pub struct Storage {
    pub(super) connection: Connection,
    pub(super) state_dir: PathBuf,
    pub(super) snapshot_gap_inputs: u64,
}

/// The operator's template image, inspected once per start through a private
/// load that leaves the image untouched. Initialization stores it only into a
/// fresh state directory; a seeded one compares its hash.
#[derive(Debug, Clone)]
pub struct Template {
    path: PathBuf,
    hash: Hash,
    awaits_input: bool,
}

impl Template {
    /// Hashes the image and refuses one without the pristine uarch of the
    /// linked emulator, which is assumed to be the deployed step's (the
    /// provenance gate's concern): every commitment shortcut assumes it at
    /// big-cycle boundaries, and every closing reset restores it, so within
    /// the node only the template can break it (custom uarch code, or an image
    /// built by an emulator with another uarch). Commitments over such a
    /// template would be silently wrong; a reset that changes the root is the
    /// test.
    pub fn inspect(path: &Path) -> anyhow::Result<Self> {
        ensure!(
            path.is_dir(),
            "machine template `{}` is not an existing directory",
            path.display()
        );
        let mut machine = Machine::load(path, &RuntimeConfig::quiet_console())
            .with_context(|| format!("failed to load template `{}`", path.display()))?;
        let hash = machine.root_hash()?;
        machine.reset_uarch()?;
        ensure!(
            machine.root_hash()? == hash,
            "template `{}` does not carry the pristine uarch of this node's emulator \
             (custom uarch code or another emulator's image); refusing it",
            path.display()
        );
        let awaits_input = crate::engine::machine_stf::awaits_input(&mut machine)?;
        Ok(Self {
            path: path.to_owned(),
            hash,
            awaits_input,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn hash(&self) -> &Hash {
        &self.hash
    }

    /// Whether an epoch can start from the template. Only startup refuses
    /// one that cannot; tests seed such templates to reach terminal states.
    pub fn awaits_input(&self) -> bool {
        self.awaits_input
    }
}

impl Storage {
    /// Opens the state directory, creating and seeding it when it is new.
    /// A directory already pinned to an engine configuration is compared
    /// with this start's before anything is written, so a wrong flag leaves
    /// it untouched: no watermark raise, no template import. A new one gets
    /// the template stored (filesystem first), then one transaction for the
    /// initial watermark (the last block treated as processed, below epoch
    /// 0's seal), the epoch-0 boundary, the template row and the pin, so a
    /// pinned directory is always a seeded one.
    pub fn initialize(
        state_dir: &Path,
        template: &Template,
        initial_watermark: u64,
        app_address: Address,
        consensus_address: Address,
        chain_id: u64,
        geometry: &TournamentGeometry,
    ) -> Result<Self> {
        create_directory_structure(state_dir)?;
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;

        let connection = open_writer_connection(&db_path(&state_dir))?;
        schema::initialize(&connection)?;

        let mut storage = Self {
            connection,
            state_dir,
            snapshot_gap_inputs: DEFAULT_SNAPSHOT_GAP_INPUTS,
        };

        let config = EngineConfig {
            structure: Structure::PRODUCTION,
            chain_id,
            app: app_address.as_slice().to_vec(),
            consensus: consensus_address.as_slice().to_vec(),
            template_hash: Digest::from_digest(template.hash()).map_err(anyhow::Error::from)?,
            emulator_version: format_emulator_version(Machine::version()),
            geometry: geometry.clone(),
        };
        match sling_config::stored(&storage.connection)? {
            Some(pinned) => check_pinned(&storage.state_dir, &pinned, &config)?,
            None => storage.seed(template, initial_watermark, &config)?,
        }

        Ok(storage)
    }

    fn seed(
        &mut self,
        template: &Template,
        initial_watermark: u64,
        config: &EngineConfig,
    ) -> Result<()> {
        // Clone the image into the store - no 500 MB re-serialization
        // through machine memory. Cross-filesystem imports degrade to a
        // sparse copy inside the clone. A crash before the commit below
        // orphans the directory, which the next seed adopts.
        let working = self
            .checkout(template.path())
            .map_err(anyhow::Error::from)?;
        let dest = self
            .commit_clone(working, template.hash())
            .map_err(anyhow::Error::from)?;

        self.write(|tx| {
            super::ingest::raise_watermark_in(tx, initial_watermark)?;
            super::snapshots::insert_snapshot_in(tx, 0, 0, template.hash(), &dest)?;
            super::snapshots::insert_template_machine_in(tx, template.hash())?;
            sling_config::pin(tx, config)?;
            Ok(())
        })
    }

    /// A writer handle onto an already-initialized database. One
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

    /// The per-epoch scratch directory (dispute logs and artifacts);
    /// filesystem lifecycle, not SQL.
    pub fn epoch_directory(&mut self, epoch_number: u64) -> Result<PathBuf> {
        create_epoch_dir(&self.state_dir, epoch_number)
    }
}

/// Writer connections: WAL, enforced foreign keys, FULL sync, and a
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

/// The template was already checked against the chain, so a pinned one that
/// differs means the directory is not this deployment's: a foreign or old one.
/// App and chain mismatches are likelier a wrong flag.
fn check_pinned(
    state_dir: &Path,
    pinned: &EngineConfig,
    given: &EngineConfig,
) -> anyhow::Result<()> {
    let dir = state_dir.display();
    ensure!(
        pinned.app == given.app,
        "data directory `{dir}` belongs to application {}, not --app-address {}: restart \
         with the right --app-address or use another --data-dir",
        alloy::hex::encode_prefixed(&pinned.app),
        alloy::hex::encode_prefixed(&given.app),
    );
    ensure!(
        pinned.chain_id == given.chain_id,
        "data directory `{dir}` belongs to chain {}, not --blockchain-id {}: restart with \
         the right --blockchain-id or use another --data-dir",
        pinned.chain_id,
        given.chain_id,
    );
    ensure!(
        pinned.template_hash == given.template_hash,
        "data directory `{dir}` was seeded from template {}, but the given template is {}: \
         the directory belongs to another deployment or is an old one; use another \
         --data-dir or wipe it",
        pinned.template_hash,
        given.template_hash,
    );
    ensure!(
        pinned == given,
        "data directory `{dir}` was built for another consensus, emulator or tournament \
         geometry: stored {pinned:?}, given {given:?}; {}",
        schema::WIPE_GUIDANCE
    );
    Ok(())
}

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
        .with_context(|| format!("creating `{}`", snapshots_path.display()))?;

    Ok(())
}

fn epoch_dir(state_dir: &Path, epoch_number: u64) -> PathBuf {
    state_dir.join(epoch_number.to_string())
}

pub(super) fn create_epoch_dir(state_dir: &Path, epoch_number: u64) -> Result<PathBuf> {
    let path = epoch_dir(state_dir, epoch_number);
    fs::create_dir_all(&path).with_context(|| format!("creating `{}`", path.display()))?;

    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::sql::test_helper::{store_template, yield_exception};
    use cartesi_machine::cartesi_machine_sys::CM_REG_UARCH_PC;

    #[test]
    fn state_dir_lock_is_exclusive() {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = dir.path().join("state");
        let held = StateDirLock::acquire(&state_dir).unwrap();
        // flock conflicts between two opens even within one process.
        let error = StateDirLock::acquire(&state_dir).unwrap_err();
        assert!(
            format!("{error:#}").contains("in use by another node process"),
            "unexpected error: {error:#}"
        );
        drop(held);
        StateDirLock::acquire(&state_dir).unwrap();
    }

    #[test]
    fn template_inspection_refuses_a_non_pristine_uarch() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        // Any uarch edit a reset would undo; custom uarch code moves the pc.
        store_template(&template, |machine| {
            machine.write_reg(CM_REG_UARCH_PC, 0x700000).unwrap();
        });
        let error = Template::inspect(&template).expect_err("a non-pristine uarch must be refused");
        assert!(
            format!("{error:#}").contains("pristine uarch"),
            "unexpected error: {error:#}"
        );
    }

    #[test]
    fn template_inspection_records_whether_an_epoch_can_start() {
        let dir = tempfile::tempdir().unwrap();
        let inspect = |name: &str, adjust: &dyn Fn(&mut Machine)| {
            let path = dir.path().join(name);
            store_template(&path, adjust);
            Template::inspect(&path).unwrap().awaits_input()
        };

        assert!(inspect("accepted", &|_| {}));
        assert!(!inspect("exception", &yield_exception));
        assert!(!inspect("running", &|machine| {
            machine
                .write_reg(cartesi_machine::cartesi_machine_sys::CM_REG_IFLAGS_Y, 0)
                .unwrap();
        }));
    }

    #[test]
    fn template_inspection_refuses_a_missing_path() {
        let dir = tempfile::tempdir().unwrap();
        let error = Template::inspect(&dir.path().join("missing")).unwrap_err();
        assert!(
            format!("{error:#}").contains("not an existing directory"),
            "unexpected error: {error:#}"
        );
    }

    fn initialize_at(
        state_dir: &Path,
        template: &Path,
        initial_watermark: u64,
        app: Address,
        chain_id: u64,
    ) -> Result<Storage> {
        Storage::initialize(
            state_dir,
            &Template::inspect(template).unwrap(),
            initial_watermark,
            app,
            Address::ZERO,
            chain_id,
            &TournamentGeometry::two_level(),
        )
    }

    /// The template matched the chain before initialization, so a pinned
    /// one that differs is a foreign or old directory, not a wrong flag.
    #[test]
    fn a_different_template_on_a_pinned_dir_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let (first, second) = (dir.path().join("first"), dir.path().join("second"));
        store_template(&first, |_| {});
        store_template(&second, |machine| {
            machine
                .write_memory(cartesi_machine::constants::ar::RAM_START, &[0xA5])
                .unwrap();
        });
        let state_dir = dir.path().join("state");
        initialize_at(&state_dir, &first, 0, Address::ZERO, 1).unwrap();

        let error = initialize_at(&state_dir, &second, 0, Address::ZERO, 1).unwrap_err();
        assert!(
            format!("{error:#}").contains("--data-dir"),
            "unexpected error: {error:#}"
        );
        let second_hash = Template::inspect(&second).unwrap().hash;
        let imported = snapshots_path(&state_dir).join(format!("0x{}", hex::encode(second_hash)));
        assert!(
            !imported.exists(),
            "a refused template must not be imported"
        );
    }

    #[test]
    fn a_different_app_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let state_dir = dir.path().join("state");
        let mut storage =
            initialize_at(&state_dir, &template, 0, Address::repeat_byte(0xaa), 1).unwrap();

        // A nonzero watermark, so a stray seed would show.
        let error =
            initialize_at(&state_dir, &template, 1000, Address::repeat_byte(0xbb), 1).unwrap_err();
        assert!(
            format!("{error:#}").contains("--app-address"),
            "unexpected error: {error:#}"
        );
        assert_eq!(storage.latest_processed_block().unwrap(), 0);
    }

    #[test]
    fn a_different_chain_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let state_dir = dir.path().join("state");
        let mut storage = initialize_at(&state_dir, &template, 0, Address::ZERO, 1).unwrap();

        let error = initialize_at(&state_dir, &template, 1000, Address::ZERO, 2).unwrap_err();
        assert!(
            format!("{error:#}").contains("--blockchain-id"),
            "unexpected error: {error:#}"
        );
        assert_eq!(storage.latest_processed_block().unwrap(), 0);
    }

    /// The caller bounds the watermark (AddressBook::initial_watermark);
    /// seeding stores it as given.
    #[test]
    fn seeding_starts_ingestion_after_the_initial_watermark() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let state_dir = dir.path().join("state");
        let mut storage = initialize_at(&state_dir, &template, 1000, Address::ZERO, 1).unwrap();
        assert_eq!(storage.latest_processed_block().unwrap(), 1000);
    }
}
