use lazy_static::lazy_static;
use rusqlite::Connection;
use rusqlite_migration::{M, Migrations};

lazy_static! {
    pub static ref MIGRATIONS: Migrations<'static> = Migrations::new(vec![
        M::up(include_str!("migrations.sql")),
        // One engine (one-engine.md section 6, amended): the runs
        // table died - the window-root row is the runner's only
        // level-0 artifact. v1's DDL no longer creates it, but a
        // store that ran the old v1 carries the table, its triggers,
        // and its never-GC'd rows forever (user_version gates by
        // number, not content); the explicit drop keeps every store
        // identical to a fresh one. IF EXISTS makes it a no-op on
        // fresh databases; SQLite drops the triggers with the table.
        M::up("DROP TABLE IF EXISTS machine_state_hashes;"),
        // Staged settlement (next/3.0 contracts): settlement_info
        // gained final_state, the post-epoch machine state hash the
        // node claims as a sentry and asserts at stage/accept. The
        // column lives in v1's DDL, so for fresh stores this step is
        // the idempotent no-op below; stores below v3 are refused in
        // migrate_to_latest instead - see the comment there.
        M::up(
            "CREATE TABLE IF NOT EXISTS settlement_info (
                epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
                computation_hash BLOB NOT NULL,
                outputs_merkle_root BLOB NOT NULL,
                outputs_merkle_root_proof BLOB NOT NULL,
                final_state BLOB NOT NULL
            );",
        ),
        // The settlement columns took the contracts' canonical names
        // (outputsMerkleRoot): v1's DDL renamed in place, so fresh
        // stores are born v4 via the idempotent no-op below, and v3
        // stores (old column names) are refused in migrate_to_latest.
        M::up(
            "CREATE TABLE IF NOT EXISTS settlement_info (
                epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
                computation_hash BLOB NOT NULL,
                outputs_merkle_root BLOB NOT NULL,
                outputs_merkle_root_proof BLOB NOT NULL,
                final_state BLOB NOT NULL
            );",
        ),
    ]);
}

/// Stores below v4 predate settlement_info's current shape (v3 added
/// final_state, which cannot be backfilled - gc_old_epochs may have
/// dropped the boundary rows that held it - and v4 renamed the
/// settlement columns to the contracts' canonical names). A partial
/// upgrade would trip the settlement asserts as a false consensus
/// alarm or fail on the old column names, so the upgrade refuses
/// loudly instead of wedging or alarming. Fresh stores initialize at
/// the current shape.
pub fn migrate_to_latest(conn: &mut Connection) -> anyhow::Result<()> {
    let version: u32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    anyhow::ensure!(
        version == 0 || version >= 4,
        "store schema v{version} predates settlement_info's current shape and cannot be \
         upgraded in place; wipe the state dir and let the node rebuild"
    );
    MIGRATIONS.to_latest(conn)?;
    Ok(())
}
