// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Clean-slate schema initialization. The store is rebuildable from the chain
//! and machine image, so incompatible stores are refused rather than migrated.

use crate::fatal::Fatal;
use anyhow::Context;
use rusqlite::{Connection, params};

const SCHEMA: &str = include_str!("schema.sql");
/// How the data directory is laid out: the tables in schema.sql and what the
/// node keeps beside them. Bump it with every change a store built by an
/// older node cannot be read under; the schema pin test makes every edit of
/// schema.sql decide.
const STORE_FORMAT: u32 = 1;
/// What stored commitments mean: leaf values and transition shapes. Bump it
/// with every change that alters them, even one that leaves the store format
/// alone.
const COMMITMENT_SEMANTICS: u32 = 2;
pub(crate) const WIPE_GUIDANCE: &str = "wipe the data directory and let the node rebuild";

fn schema_is_empty(conn: &Connection) -> anyhow::Result<bool> {
    let object_count: u64 =
        conn.query_row("SELECT COUNT(*) FROM sqlite_schema", [], |row| row.get(0))?;
    Ok(object_count == 0)
}

/// Creates and stamps an empty database. A nonempty database is accepted only
/// when its store format and commitment semantics match this binary.
pub fn initialize(conn: &Connection) -> anyhow::Result<()> {
    let tx = conn
        .unchecked_transaction()
        .context("begin current-schema initialization")?;

    if schema_is_empty(&tx)? {
        tx.execute_batch(SCHEMA)
            .context("create current node database schema")?;
        tx.execute(
            "INSERT INTO node_metadata (id, store_format, commitment_semantics)
             VALUES (0, ?1, ?2)",
            params![STORE_FORMAT, COMMITMENT_SEMANTICS],
        )
        .context("stamp current node database identity")?;
        tx.commit()
            .context("commit current-schema initialization")?;
        return Ok(());
    }

    // An older store may lack the table, the columns or the row; each is
    // a store this node cannot read.
    let (store_format, semantics): (u32, u32) = tx
        .query_row(
            "SELECT store_format, commitment_semantics FROM node_metadata WHERE id = 0",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|e| {
            Fatal::rebuild(format!(
                "database has no readable store format ({e}): an older node built it; \
                 {WIPE_GUIDANCE}"
            ))
        })?;
    anyhow::ensure!(
        store_format == STORE_FORMAT,
        Fatal::rebuild(format!(
            "database has store format {store_format}, but this node reads {STORE_FORMAT}; \
             {WIPE_GUIDANCE}"
        ))
    );
    anyhow::ensure!(
        semantics == COMMITMENT_SEMANTICS,
        Fatal::rebuild(format!(
            "database holds commitments under semantics {semantics}, but this node \
             uses {COMMITMENT_SEMANTICS}; {WIPE_GUIDANCE}"
        ))
    );

    tx.commit()
        .context("commit current-schema compatibility check")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply_schema_with_identity(conn: &Connection, store_format: u32, semantics: u32) {
        conn.execute_batch(SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO node_metadata (id, store_format, commitment_semantics)
             VALUES (0, ?1, ?2)",
            params![store_format, semantics],
        )
        .unwrap();
    }

    fn assert_wipe_error(error: anyhow::Error, expected: &str) {
        assert_eq!(crate::fatal::exit_code(&error), 40, "{error:#}");
        let error = format!("{error:#}");
        assert!(
            error.contains(expected) && error.contains(WIPE_GUIDANCE),
            "unexpected initialization error: {error}"
        );
    }

    /// Keccak-256 of schema.sql, pinned by the test below.
    const SCHEMA_PIN: &str = "668596323ec38dc1ecf5c6fa4fda8f5d6099a1bb5006a321361e1a75951db094";

    /// An edit of schema.sql fails here until its author decides whether a
    /// store built before it is still readable: if not, bump STORE_FORMAT.
    /// Either way, update the pin.
    #[test]
    fn schema_edits_decide_the_store_format() {
        assert_eq!(
            alloy::hex::encode(alloy::primitives::keccak256(SCHEMA)),
            SCHEMA_PIN,
            "schema.sql changed: bump STORE_FORMAT unless older stores stay readable, \
             then update the pin"
        );
    }

    #[test]
    fn fresh_database_is_created_and_stamped() {
        let conn = Connection::open_in_memory().unwrap();

        initialize(&conn).unwrap();

        let stamps: (u32, u32) = conn
            .query_row(
                "SELECT store_format, commitment_semantics FROM node_metadata WHERE id = 0",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(stamps, (STORE_FORMAT, COMMITMENT_SEMANTICS));
    }

    #[test]
    fn current_database_reopens_without_reapplying_schema() {
        let conn = Connection::open_in_memory().unwrap();
        initialize(&conn).unwrap();
        conn.execute("INSERT INTO epochs VALUES (0, 0, '0x00', 0)", [])
            .unwrap();

        initialize(&conn).unwrap();

        let epoch_count: u64 = conn
            .query_row("SELECT COUNT(*) FROM epochs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(epoch_count, 1);
    }

    #[test]
    fn legacy_nonempty_database_is_refused_without_mutation() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(include_str!("testdata/obsolete_settlement_schema.sql"))
            .unwrap();
        conn.execute("INSERT INTO settlement_info VALUES (7, zeroblob(32))", [])
            .unwrap();
        let schema_version_before: u64 = conn
            .query_row("PRAGMA schema_version", [], |row| row.get(0))
            .unwrap();

        assert_wipe_error(initialize(&conn).unwrap_err(), "no readable store format");
        let schema_version_after: u64 = conn
            .query_row("PRAGMA schema_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(schema_version_after, schema_version_before);
        let legacy_rows: u64 = conn
            .query_row("SELECT COUNT(*) FROM settlement_info", [], |row| row.get(0))
            .unwrap();
        assert_eq!(legacy_rows, 1);
    }

    #[test]
    fn missing_metadata_row_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();

        assert_wipe_error(initialize(&conn).unwrap_err(), "no readable store format");
    }

    #[test]
    fn different_store_format_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        apply_schema_with_identity(&conn, STORE_FORMAT + 1, COMMITMENT_SEMANTICS);

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            &format!("store format {}", STORE_FORMAT + 1),
        );
    }

    #[test]
    fn different_commitment_semantics_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        apply_schema_with_identity(&conn, STORE_FORMAT, COMMITMENT_SEMANTICS + 1);

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            "commitments under semantics",
        );
    }

    #[test]
    fn settlement_proof_blobs_have_exact_schema_lengths() {
        let conn = Connection::open_in_memory().unwrap();
        initialize(&conn).unwrap();

        let error = conn
            .execute(
                "INSERT INTO settlement_info VALUES (
                    0, zeroblob(32), zeroblob(32),
                    zeroblob(32), zeroblob(1887),
                    zeroblob(32), zeroblob(1888),
                    zeroblob(32), zeroblob(1888)
                )",
                [],
            )
            .unwrap_err();
        assert!(
            error.to_string().contains("CHECK constraint failed"),
            "unexpected settlement shape error: {error}"
        );
    }
}
