// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! `Storage` definition, connection lifecycle, and the transaction
//! closure helpers. Writer-role method clusters live in sibling files
//! (`ingest`, `advance`, `dispute`, `queries`), each adding its own
//! `impl Storage`.

use super::error::Result;
use super::sql::schema;
use crate::engine::constants::{UARCH_STATE_LOG2_SIZE, UARCH_STATE_START};
use crate::engine::{EngineConfig, config as sling_config};
use crate::fatal::Fatal;
use anyhow::{Context, ensure};
use cartesi_machine::{
    config::{
        machine::{HashFunctionType, MachineConfig},
        runtime::RuntimeConfig,
    },
    machine::Machine,
    types::Hash,
};
use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Duration,
};

/// SQLite `synchronous` pragma for every connection. FULL, because a
/// commit gates an external effect: snapshot directories are removed
/// once the commit that stops referencing them lands, and under NORMAL
/// a power loss can undo that commit while the removals persist,
/// leaving rows that name missing directories. The node commits a few
/// times per tick, so the extra fsync is free.
const SYNCHRONOUS_PRAGMA: &str = "FULL";

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
}

/// The operator's machine image, inspected only to seed a new state
/// directory, through a private load that leaves the image untouched.
#[derive(Debug, Clone)]
pub struct Template {
    path: PathBuf,
    hash: Hash,
    awaits_input: bool,
}

impl Template {
    /// Hashes the image and refuses one without the pristine uarch of the
    /// linked emulator, which startup checks is the deployed step's (in
    /// `discover_deployed_tournament`): every commitment shortcut assumes it at
    /// big-cycle boundaries, and every closing reset restores it, so within
    /// the node only the template can break it (custom uarch code, or an image
    /// built by an emulator with another uarch). Commitments over such a
    /// template would be silently wrong. A template is a big-cycle boundary,
    /// so its uarch state's node must hash to the linked emulator's pristine
    /// uarch hash.
    ///
    /// It also refuses an image whose files the runner maps shared for
    /// writing lack the owner write bit: seeding clones the image keeping
    /// each file's mode (hard-linking one without write bits), so such an
    /// image seeds fine and then fails every advance batch.
    pub fn inspect(path: &Path) -> anyhow::Result<Self> {
        ensure!(
            path.is_dir(),
            Fatal::terminal(format!(
                "machine template `{}` is not an existing directory",
                path.display()
            ))
        );
        let mut machine = Machine::load(path, &RuntimeConfig::quiet_console())
            .with_context(|| format!("failed to load template `{}`", path.display()))?;
        // The root hash comes from the image's stored hash tree, which a load
        // does not check against pages marked clean.
        // TODO: uncomment after the emulator release that supports
        // cm_verify_hash_tree (docs/todo.md), with the binding it calls
        // (cartesi-machine's machine.rs), un-ignore its test below, and then
        // drop the notes that say to trust the seed image's source (the node
        // README's operator notes and docs/node-architecture.md's startup
        // section).
        // ensure!(
        //     machine.verify_hash_tree()?,
        //     Fatal::terminal(format!(
        //         "--template-path `{}`: the image's stored hash tree does not match \
        //          its contents (a corrupt or forged image); refusing it",
        //         path.display()
        //     ))
        // );
        let hash = machine.root_hash()?;
        let config = machine.initial_config()?;
        // Under any other hash function the comparison below fails for that
        // reason alone, and would blame the uarch.
        let hash_function = &config.hash_tree.hash_function;
        ensure!(
            *hash_function == HashFunctionType::Keccak256,
            Fatal::terminal(format!(
                "template `{}` uses a {hash_function:?} hash tree, but the uarch and the \
                 on-chain step need Keccak-256; refusing it",
                path.display()
            ))
        );
        for file in shared_writable_files(&config) {
            let mode = fs::metadata(file)
                .with_context(|| format!("reading `{}`", file.display()))?
                .permissions()
                .mode();
            ensure!(
                mode & 0o200 != 0,
                Fatal::terminal(format!(
                    "template `{}`: `{}` lacks the owner write bit, but every advance batch \
                     maps it shared for writing, and seeding keeps file modes; make the \
                     template's files writable (e.g. `chmod -R u+w {}`); refusing it",
                    path.display(),
                    file.display(),
                    path.display(),
                ))
            );
        }
        let uarch_hash = machine.node_hash(UARCH_STATE_START, UARCH_STATE_LOG2_SIZE)?;
        let linked_hash = Machine::uarch_pristine_hash();
        ensure!(
            uarch_hash == linked_hash,
            Fatal::terminal(format!(
                "template `{}` does not carry the linked emulator's pristine uarch: its uarch \
                 state hash is {}, the linked emulator's {} (custom uarch code or another \
                 emulator's image); refusing it",
                path.display(),
                alloy::hex::encode_prefixed(uarch_hash),
                alloy::hex::encode_prefixed(linked_hash),
            ))
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

/// The files of a stored machine that a `SharingMode::All` load (every
/// runner batch) opens for writing: each range's data and dirty-tree files
/// and the hash tree's, except the data of ranges the host maps read-only
/// (the PMAs and read-only drives), which the emulator itself stores
/// read-only. The ranges are those the emulator's `machine::clone_stored`
/// clones.
fn shared_writable_files(config: &MachineConfig) -> Vec<&Path> {
    let fixed = [
        (&config.processor.backing_store, false),
        (&config.pmas.backing_store, true),
        (&config.dtb.backing_store, false),
        (&config.ram.backing_store, false),
        (&config.cmio.rx_buffer.backing_store, false),
        (&config.cmio.tx_buffer.backing_store, false),
        (&config.uarch.processor.backing_store, false),
        (&config.uarch.ram.backing_store, false),
    ];
    let drives = (config.flash_drive.iter())
        .chain(&config.nvram)
        .map(|drive| (&drive.backing_store, drive.read_only));
    let mut files = vec![
        config.hash_tree.sht_filename.as_path(),
        config.hash_tree.phtc_filename.as_path(),
    ];
    for (store, host_read_only) in fixed.into_iter().chain(drives) {
        if !host_read_only {
            files.push(&store.data_filename);
        }
        files.extend([store.dht_filename.as_path(), store.dpt_filename.as_path()]);
    }
    files
}

/// What a new state directory starts from: the image of `epoch`'s start
/// and the initial watermark, the last block ingestion treats as processed
/// (below epoch 0's seal).
#[derive(Debug, Clone)]
pub struct Seed {
    pub image: Template,
    pub epoch: u64,
    pub watermark: u64,
}

impl Storage {
    /// Whether the state directory holds a seeded database, probed before
    /// the lock without creating anything: startup reads its image only
    /// when it does not. A database without a pin (a crash inside seeding)
    /// is not seeded, so the next start seeds it and adopts the orphaned
    /// clone. `initialize` decides again under the lock.
    pub fn is_seeded(state_dir: &Path) -> Result<bool> {
        let path = db_path(state_dir);
        if !path
            .try_exists()
            .with_context(|| format!("probing `{}`", path.display()))?
        {
            return Ok(false);
        }
        // Read-write without create: a read-only open of a WAL database is
        // fragile after a crash.
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(Duration::from_secs(10))?;
        let has_pins: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema
                           WHERE type = 'table' AND name = 'sling_config')",
            [],
            |row| row.get(0),
        )?;
        if !has_pins {
            return Ok(false);
        }
        // Names no column, so a store of another shape reaches the
        // format refusal under the lock instead of an error here.
        let pinned =
            connection.query_row("SELECT EXISTS(SELECT 1 FROM sling_config)", [], |row| {
                row.get(0)
            })?;
        Ok(pinned)
    }

    /// Opens the state directory, creating and seeding it when it is new.
    /// A directory already pinned to an engine configuration is compared
    /// with this start's before anything is written, so a wrong flag leaves
    /// it untouched, and its image is never read again. A new one gets the
    /// seed image stored (filesystem first), then one transaction for the
    /// seed's watermark, its epoch's start boundary, the completion cursor at
    /// that epoch and the pin, so a pinned directory is always a seeded one.
    /// The caller holds the directory's lock ([`StateDirLock`]): the staging
    /// sweep removes working clones no other process may still hold.
    pub fn initialize(
        state_dir: &Path,
        seed: Option<&Seed>,
        config: &EngineConfig,
    ) -> Result<Self> {
        create_directory_structure(state_dir)?;
        let state_dir = state_dir.canonicalize().map_err(anyhow::Error::from)?;

        let connection = open_writer_connection(&db_path(&state_dir))?;
        schema::initialize(&connection)?;

        let mut storage = Self {
            connection,
            state_dir,
        };
        // Before the seed: its working clone's name repeats on every start
        // where the PID does (a container's PID 1), so a seed interrupted
        // there would otherwise find the name taken forever.
        storage.sweep_stale_staging()?;

        match (sling_config::stored(&storage.connection)?, seed) {
            (Some(pinned), seed) => {
                check_pinned(&storage.state_dir, &pinned, config)?;
                if seed.is_some() {
                    log::info!(
                        "data directory `{}` was seeded after the startup probe; the given \
                         image is not used",
                        storage.state_dir.display()
                    );
                }
            }
            (None, Some(seed)) => storage.seed(seed, config)?,
            (None, None) => {
                return Err(anyhow::anyhow!(
                    "data directory `{}` lost its seed after the startup probe found one: \
                     restart the node",
                    storage.state_dir.display()
                )
                .into());
            }
        }

        Ok(storage)
    }

    fn seed(&mut self, seed: &Seed, config: &EngineConfig) -> Result<()> {
        let image = &seed.image;
        // Clone the image into the store - no 500 MB re-serialization
        // through machine memory. Cross-filesystem imports degrade to a
        // sparse copy inside the clone. A crash before the clone is
        // published leaves staging, which the next start sweeps; one after
        // it orphans the directory, which the next seed adopts.
        let working = self.checkout(image.path())?;
        self.commit_clone(working, image.hash())?;

        self.write(|tx| {
            super::ingest::raise_watermark_in(tx, seed.watermark)?;
            super::snapshots::insert_snapshot_in(tx, seed.epoch, 0, image.hash())?;
            super::completion::seed_cursor_in(tx, seed.epoch)?;
            sling_config::pin(tx, config)?;
            Ok(())
        })?;
        let below = if seed.epoch > 0 {
            "; the node does not touch earlier epochs"
        } else {
            ""
        };
        log::info!(
            "seeded data directory `{}` at epoch {} from image {}{below}",
            self.state_dir.display(),
            seed.epoch,
            alloy::hex::encode_prefixed(image.hash()),
        );
        Ok(())
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
        })
    }

    /// Bytes an unprivileged writer may still allocate on the data
    /// directory's filesystem.
    pub fn free_bytes(&self) -> std::io::Result<u64> {
        use std::os::unix::ffi::OsStrExt;
        let path = std::ffi::CString::new(self.state_dir.as_os_str().as_bytes())?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
        // SAFETY: a NUL-terminated path and a buffer statvfs fills on success.
        if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: statvfs succeeded, so it initialized the buffer.
        let stat = unsafe { stat.assume_init() };
        // The field widths differ across platforms.
        #[allow(clippy::unnecessary_cast)]
        Ok((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
    }

    /// The data directory's filesystem type, for the startup line:
    /// production expects XFS with reflinks (README).
    pub fn filesystem(&self) -> std::io::Result<String> {
        use std::os::unix::ffi::OsStrExt;
        let path = std::ffi::CString::new(self.state_dir.as_os_str().as_bytes())?;
        let mut stat = std::mem::MaybeUninit::<libc::statfs>::zeroed();
        // SAFETY: a NUL-terminated path and a buffer statfs fills on success.
        if unsafe { libc::statfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: statfs succeeded, so it initialized the buffer.
        Ok(filesystem_name(&unsafe { stat.assume_init() }))
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
            .transaction_with_behavior(TransactionBehavior::Deferred)?;
        let out = f(&tx)?;
        tx.commit()?;
        Ok(out)
    }

    /// Runs `f` inside an Immediate transaction, committing on
    /// success. For mutations: Immediate takes the write lock at
    /// BEGIN, so a contending writer waits at the boundary of the
    /// domain operation instead of failing mid-transaction. On `Err`
    /// the transaction drops unsent - automatic rollback.
    pub(super) fn write<T>(&mut self, f: impl FnOnce(&Transaction) -> Result<T>) -> Result<T> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let out = f(&tx)?;
        tx.commit()?;
        Ok(out)
    }
}

/// Writer connections: WAL, FULL sync, and a generous busy timeout
/// (machine work happens between transactions, never inside one, so
/// writers only contend for row-commit bursts).
fn open_writer_connection(db_path: &Path) -> Result<Connection> {
    let connection = Connection::open(db_path)?;
    configure_writer_pragmas(&connection)?;
    Ok(connection)
}

fn configure_writer_pragmas(connection: &Connection) -> Result<()> {
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", SYNCHRONOUS_PRAGMA)?;
    connection.busy_timeout(std::time::Duration::from_secs(10))?;
    Ok(())
}

//
// State directory layout
//

/// Both initial hashes are the deployment's, read from chain, so with the
/// same app and chain a differing one means the directory is another
/// deployment's: an old one at the same addresses. App and chain mismatches
/// are likelier a wrong flag.
fn check_pinned(
    state_dir: &Path,
    pinned: &EngineConfig,
    given: &EngineConfig,
) -> anyhow::Result<()> {
    let dir = state_dir.display();
    ensure!(
        pinned.app == given.app,
        Fatal::terminal(format!(
            "data directory `{dir}` belongs to application {}, not --app-address {}: restart \
             with the right --app-address or use another --data-dir",
            alloy::hex::encode_prefixed(&pinned.app),
            alloy::hex::encode_prefixed(&given.app),
        ))
    );
    ensure!(
        pinned.chain_id == given.chain_id,
        Fatal::terminal(format!(
            "data directory `{dir}` belongs to chain {}, not --blockchain-id {}: restart with \
             the right --blockchain-id or use another --data-dir",
            pinned.chain_id, given.chain_id,
        ))
    );
    ensure!(
        pinned.template_hash == given.template_hash,
        Fatal::terminal(format!(
            "data directory `{dir}` belongs to a deployment starting from {}, but application \
             {} on this chain starts from {}: the directory is another deployment's or an old \
             one (a redeployment at the same addresses); use another --data-dir or wipe it",
            pinned.template_hash,
            alloy::hex::encode_prefixed(&given.app),
            given.template_hash,
        ))
    );
    ensure!(
        pinned == given,
        Fatal::rebuild(format!(
            "data directory `{dir}` was built for another consensus, emulator or tournament \
             geometry: stored {pinned:?}, given {given:?}; {}",
            schema::WIPE_GUIDANCE
        ))
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

/// The magic numbers of the filesystems the README names (linux/magic.h).
#[cfg(target_os = "linux")]
fn filesystem_name(stat: &libc::statfs) -> String {
    // f_type's width differs across architectures; the magics are 32-bit.
    let name = match stat.f_type as u32 {
        0x5846_5342 => "xfs",
        0xEF53 => "ext4",
        0x9123_683E => "btrfs",
        0x2FC1_2FC1 => "zfs",
        0x0102_1994 => "tmpfs",
        0x794C_7630 => "overlayfs",
        0x6969 => "nfs",
        other => return format!("{other:#x}"),
    };
    name.to_owned()
}

#[cfg(not(target_os = "linux"))]
fn filesystem_name(stat: &libc::statfs) -> String {
    // SAFETY: the kernel NUL-terminates f_fstypename.
    unsafe { std::ffi::CStr::from_ptr(stat.f_fstypename.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

fn create_directory_structure(state_dir: &Path) -> Result<()> {
    create_empty_state_dir_if_needed(state_dir)?;

    let snapshots_path = snapshots_path(state_dir);
    fs::create_dir_all(&snapshots_path)
        .with_context(|| format!("creating `{}`", snapshots_path.display()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::TournamentGeometry;
    use crate::storage::sql::test_helper::{store_template, yield_exception};
    use alloy::primitives::Address;
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
        // Any edit of the uarch state; custom uarch code moves the pc.
        store_template(&template, |machine| {
            machine.write_reg(CM_REG_UARCH_PC, 0x700000).unwrap();
        });
        let error = Template::inspect(&template).expect_err("a non-pristine uarch must be refused");
        let error = format!("{error:#}");
        let linked = alloy::hex::encode_prefixed(Machine::uarch_pristine_hash());
        assert!(
            error.contains("pristine uarch: its uarch state hash is 0x")
                && error.contains(&format!("the linked emulator's {linked}")),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn template_inspection_refuses_a_non_keccak_hash_tree() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        let mut config = Machine::default_config().unwrap();
        config.ram.length = 4096;
        config.hash_tree.hash_function = HashFunctionType::Sha256;
        Machine::create(&config, &RuntimeConfig::default())
            .unwrap()
            .store(&template)
            .unwrap();
        let error = Template::inspect(&template).expect_err("a SHA-256 hash tree must be refused");
        assert!(
            format!("{error:#}").contains("uses a Sha256 hash tree"),
            "unexpected error: {error:#}"
        );
    }

    /// A load takes the root hash from the stored tree on pages marked clean,
    /// so contents edited behind a clean tree keep the old root.
    #[test]
    #[ignore = "enable with the commented-out cm_verify_hash_tree check in Template::inspect, \
                after the emulator release that supports it (docs/todo.md)"]
    fn template_inspection_refuses_a_stale_hash_tree() {
        use std::os::unix::fs::FileExt;
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        // A shared load whose root hash is taken leaves the stored tree
        // exact and every page clean.
        let ram = {
            let mut machine = Machine::load_with_sharing(
                &template,
                &RuntimeConfig::quiet_console(),
                cartesi_machine::types::SharingMode::All,
            )
            .unwrap();
            machine.root_hash().unwrap();
            machine
                .initial_config()
                .unwrap()
                .ram
                .backing_store
                .data_filename
        };
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&ram)
            .unwrap();
        let mut bytes = [0; 32];
        file.read_exact_at(&mut bytes, 0).unwrap();
        file.write_all_at(&bytes.map(|byte| !byte), 0).unwrap();
        drop(file);

        let error = Template::inspect(&template).expect_err("a stale hash tree must be refused");
        assert!(
            format!("{error:#}").contains("stored hash tree does not match"),
            "unexpected error: {error:#}"
        );
        assert_eq!(crate::fatal::exit_code(&error), 30);
    }

    /// A read-only template seeds (cloning hard-links its files into the
    /// store) and then fails every batch, so inspection refuses it first.
    #[test]
    fn template_inspection_refuses_files_the_runner_must_write() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let hash = *Template::inspect(&template).unwrap().hash();
        // chmod a-w on the files; the directory stays traversable.
        for entry in fs::read_dir(&template).unwrap() {
            let path = entry.unwrap().path();
            let mode = fs::metadata(&path).unwrap().permissions().mode();
            fs::set_permissions(&path, fs::Permissions::from_mode(mode & !0o222)).unwrap();
        }

        let error = Template::inspect(&template).expect_err("a read-only template must be refused");
        assert!(
            format!("{error:#}").contains("lacks the owner write bit"),
            "unexpected error: {error:#}"
        );
        assert_eq!(crate::fatal::exit_code(&error), 30);

        // What the refusal prevents: past inspection, the seed succeeds and
        // the runner's first batch cannot open its working clone.
        let image = Template {
            path: template,
            hash,
            awaits_input: true,
        };
        let seed = Seed {
            image,
            epoch: 0,
            watermark: 0,
        };
        let state_dir = dir.path().join("state");
        let mut storage =
            Storage::initialize(&state_dir, Some(&seed), &config(Address::ZERO, 1, hash)).unwrap();
        assert!(storage.begin_advances().is_err());
    }

    /// Only files the runner writes need the bit: a read-only drive (and the
    /// PMAs, which every stored image keeps read-only) passes.
    #[test]
    fn template_inspection_accepts_a_read_only_drive() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        let mut config = Machine::default_config().unwrap();
        config.ram.length = 4096;
        config.flash_drive = vec![cartesi_machine::config::machine::MemoryRangeConfig {
            start: 1 << 55,
            length: 4096,
            read_only: true,
            ..Default::default()
        }];
        Machine::create(&config, &RuntimeConfig::default())
            .unwrap()
            .store(&template)
            .unwrap();
        let drive = template.join(format!("{:016x}-1000.bin", 1u64 << 55));
        assert_eq!(
            fs::metadata(&drive).unwrap().permissions().mode() & 0o222,
            0
        );
        Template::inspect(&template).unwrap();
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

    fn config(app: Address, chain_id: u64, initial_hash: Hash) -> EngineConfig {
        EngineConfig::for_deployment(
            chain_id,
            app,
            Address::ZERO,
            initial_hash,
            TournamentGeometry::two_level(),
        )
    }

    /// Opens `state_dir`, seeding it at epoch 0 from `template` when new;
    /// the template stands for the deployment's initial state.
    fn initialize_at(
        state_dir: &Path,
        template: &Path,
        initial_watermark: u64,
        app: Address,
        chain_id: u64,
    ) -> Result<Storage> {
        let image = Template::inspect(template).unwrap();
        let config = config(app, chain_id, *image.hash());
        let seed = Seed {
            image,
            epoch: 0,
            watermark: initial_watermark,
        };
        Storage::initialize(state_dir, Some(&seed), &config)
    }

    #[test]
    fn the_probe_finds_only_a_seeded_directory_and_creates_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = dir.path().join("state");
        assert!(!Storage::is_seeded(&state_dir).unwrap());
        assert!(
            !state_dir.exists(),
            "the probe must not create the directory"
        );

        // A crash between schema creation and the seed's commit.
        fs::create_dir(&state_dir).unwrap();
        schema::initialize(&Connection::open(db_path(&state_dir)).unwrap()).unwrap();
        assert!(!Storage::is_seeded(&state_dir).unwrap());

        let template = dir.path().join("template");
        store_template(&template, |_| {});
        initialize_at(&state_dir, &template, 0, Address::ZERO, 1).unwrap();
        assert!(Storage::is_seeded(&state_dir).unwrap());
    }

    /// A seed killed mid-clone leaves its working clone; under a stable PID
    /// the next seed's clone would take the same name and fail on it, so
    /// initialize sweeps staging before seeding. The checkout counter is
    /// process-wide, so the suite proves the sweep; the collision with the
    /// planted `-0` name, and so the ordering, only when this test runs
    /// alone.
    #[test]
    fn a_seed_starts_from_swept_staging() {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = dir.path().join("state");
        let snapshots = snapshots_path(&state_dir);
        let leftovers = [
            snapshots.join(format!(".work-{}-0", std::process::id())),
            snapshots.join(".part-0xdead"),
        ];
        for leftover in &leftovers {
            fs::create_dir_all(leftover).unwrap();
            fs::write(leftover.join("config.json"), b"torn").unwrap();
        }

        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let mut storage = initialize_at(&state_dir, &template, 0, Address::ZERO, 1).unwrap();
        assert!(storage.snapshot_dir(0, 0).unwrap().unwrap().is_dir());
        assert!(Storage::is_seeded(&state_dir).unwrap());
        for leftover in &leftovers {
            assert!(!leftover.exists(), "`{}` survived", leftover.display());
        }
    }

    /// A seeded directory never reads its image again (COMP-3).
    #[test]
    fn a_seeded_directory_reopens_without_its_image() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let state_dir = dir.path().join("state");
        let hash = *Template::inspect(&template).unwrap().hash();
        initialize_at(&state_dir, &template, 1000, Address::ZERO, 1).unwrap();
        fs::remove_dir_all(&template).unwrap();

        let mut storage =
            Storage::initialize(&state_dir, None, &config(Address::ZERO, 1, hash)).unwrap();
        assert_eq!(storage.latest_processed_block().unwrap(), 1000);
        assert_eq!(storage.snapshot_hash(0, 0).unwrap(), Some(hash));
        drop(storage);

        // A seed that reaches a pinned directory (another start won the race
        // after the probe) is ignored: nothing is imported or written.
        let other = dir.path().join("other");
        store_template(&other, |machine| {
            machine
                .write_memory(cartesi_machine::constants::ar::RAM_START, &[0xA5])
                .unwrap();
        });
        let image = Template::inspect(&other).unwrap();
        let other_hash = *image.hash();
        let seed = Seed {
            image,
            epoch: 2,
            watermark: 5000,
        };
        let mut storage =
            Storage::initialize(&state_dir, Some(&seed), &config(Address::ZERO, 1, hash)).unwrap();
        assert_eq!(storage.latest_processed_block().unwrap(), 1000);
        assert_eq!(storage.snapshot_hash(0, 0).unwrap(), Some(hash));
        assert!(storage.snapshot_hash(2, 0).unwrap().is_none());
        assert!(
            !snapshots_path(&state_dir)
                .join(format!("0x{}", hex::encode(other_hash)))
                .exists(),
            "a seed given to a pinned directory must not be imported"
        );
    }

    /// The probe found a seed the locked open does not: another process
    /// raced it, so the start fails and a restart seeds.
    #[test]
    fn an_unseeded_directory_needs_a_seed() {
        let dir = tempfile::tempdir().unwrap();
        let error = Storage::initialize(
            &dir.path().join("state"),
            None,
            &config(Address::ZERO, 1, [0; 32]),
        )
        .unwrap_err();
        assert!(
            format!("{error:#}").contains("lost its seed"),
            "unexpected error: {error:#}"
        );
        assert_eq!(crate::fatal::exit_code(&error.into()), 1);
    }

    /// Both hashes come from chain, so a pinned one that differs is another
    /// deployment's directory, not a wrong flag; nothing is written.
    #[test]
    fn another_deployment_on_a_pinned_dir_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let (first, second) = (dir.path().join("first"), dir.path().join("second"));
        store_template(&first, |_| {});
        store_template(&second, |machine| {
            machine
                .write_memory(cartesi_machine::constants::ar::RAM_START, &[0xA5])
                .unwrap();
        });
        let state_dir = dir.path().join("state");
        let mut storage = initialize_at(&state_dir, &first, 0, Address::ZERO, 1).unwrap();

        // A nonzero watermark, so a stray seed would show.
        let error = initialize_at(&state_dir, &second, 1000, Address::ZERO, 1).unwrap_err();
        assert!(
            format!("{error:#}").contains("--data-dir"),
            "unexpected error: {error:#}"
        );
        assert_eq!(crate::fatal::exit_code(&error.into()), 30);
        assert_eq!(storage.latest_processed_block().unwrap(), 0);
        let second_hash = Template::inspect(&second).unwrap().hash;
        let imported = snapshots_path(&state_dir).join(format!("0x{}", hex::encode(second_hash)));
        assert!(!imported.exists(), "a refused image must not be imported");
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
        assert_eq!(crate::fatal::exit_code(&error.into()), 30);
        assert_eq!(storage.latest_processed_block().unwrap(), 0);
    }

    #[test]
    fn free_space_is_read_from_the_data_directory_filesystem() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let storage =
            initialize_at(&dir.path().join("state"), &template, 0, Address::ZERO, 1).unwrap();
        assert!(storage.free_bytes().unwrap() > 0);
        assert!(!storage.filesystem().unwrap().is_empty());
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

    /// Drift in the pinned row past app, chain and initial hash (here the
    /// consensus or the geometry) asks for a rebuild, and writes nothing
    /// first. The emulator is linked, so a test cannot drift it.
    #[test]
    fn a_drifted_config_needs_a_rebuild() {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("template");
        store_template(&template, |_| {});
        let state_dir = dir.path().join("state");
        let mut storage = initialize_at(&state_dir, &template, 0, Address::ZERO, 1).unwrap();

        for (consensus, geometry) in [
            (Address::repeat_byte(0xcc), TournamentGeometry::two_level()),
            (Address::ZERO, TournamentGeometry::three_level()),
        ] {
            let image = Template::inspect(&template).unwrap();
            let config =
                EngineConfig::for_deployment(1, Address::ZERO, consensus, *image.hash(), geometry);
            // A nonzero watermark, so a stray seed would show.
            let seed = Seed {
                image,
                epoch: 0,
                watermark: 1000,
            };
            let error = Storage::initialize(&state_dir, Some(&seed), &config).unwrap_err();
            assert_eq!(crate::fatal::exit_code(&error.into()), 40);
        }
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
