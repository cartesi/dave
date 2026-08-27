// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Clean-slate schema initialization. The store is rebuildable from the chain
//! and machine image, so incompatible stores are refused rather than migrated.

use alloy::primitives::{B256, keccak256};
use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, params};

const SCHEMA: &str = include_str!("schema.sql");
const NODE_VERSION: &str = env!("CARGO_PKG_VERSION");
const WIPE_GUIDANCE: &str = "wipe the state dir and let the node rebuild";

fn schema_fingerprint() -> B256 {
    keccak256(SCHEMA.as_bytes())
}

fn schema_is_empty(conn: &Connection) -> anyhow::Result<bool> {
    let object_count: u64 =
        conn.query_row("SELECT COUNT(*) FROM sqlite_schema", [], |row| row.get(0))?;
    Ok(object_count == 0)
}

/// Creates and stamps an empty database. A nonempty database is accepted only
/// when its immutable node version and schema fingerprint match this binary.
pub fn initialize(conn: &Connection) -> anyhow::Result<()> {
    let tx = conn
        .unchecked_transaction()
        .context("begin current-schema initialization")?;
    let expected_fingerprint = schema_fingerprint();

    if schema_is_empty(&tx)? {
        tx.execute_batch(SCHEMA)
            .context("create current node database schema")?;
        tx.execute(
            "INSERT INTO node_metadata (id, node_version, schema_fingerprint)
             VALUES (0, ?1, ?2)",
            params![NODE_VERSION, expected_fingerprint.as_slice()],
        )
        .context("stamp current node database identity")?;
        tx.commit()
            .context("commit current-schema initialization")?;
        return Ok(());
    }

    let has_metadata_table: bool = tx.query_row(
        "SELECT EXISTS (
             SELECT 1 FROM sqlite_schema
             WHERE type = 'table' AND name = 'node_metadata'
         )",
        [],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        has_metadata_table,
        "database predates node compatibility metadata; {WIPE_GUIDANCE}"
    );

    let stored = tx
        .query_row(
            "SELECT node_version, schema_fingerprint
             FROM node_metadata WHERE id = 0",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
        )
        .optional()
        .with_context(|| format!("database compatibility metadata is invalid; {WIPE_GUIDANCE}"))?;
    let (stored_version, stored_fingerprint) = stored.ok_or_else(|| {
        anyhow::anyhow!(
            "database compatibility metadata is missing; initialization may be incomplete; \
             {WIPE_GUIDANCE}"
        )
    })?;

    anyhow::ensure!(
        stored_version == NODE_VERSION,
        "database belongs to node version {stored_version}, but this node is version \
         {NODE_VERSION}; {WIPE_GUIDANCE}"
    );
    anyhow::ensure!(
        stored_fingerprint.as_slice() == expected_fingerprint.as_slice(),
        "database schema fingerprint {} does not match this node's {}; {WIPE_GUIDANCE}",
        hex::encode(stored_fingerprint),
        hex::encode(expected_fingerprint.as_slice())
    );

    tx.commit()
        .context("commit current-schema compatibility check")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply_schema_with_identity(conn: &Connection, version: &str, fingerprint: &[u8]) {
        conn.execute_batch(SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO node_metadata (id, node_version, schema_fingerprint)
             VALUES (0, ?1, ?2)",
            params![version, fingerprint],
        )
        .unwrap();
    }

    fn assert_wipe_error(error: anyhow::Error, expected: &str) {
        let error = format!("{error:#}");
        assert!(
            error.contains(expected) && error.contains(WIPE_GUIDANCE),
            "unexpected initialization error: {error}"
        );
    }

    #[test]
    fn fresh_database_is_created_and_stamped() {
        let conn = Connection::open_in_memory().unwrap();

        initialize(&conn).unwrap();

        let (version, fingerprint): (String, Vec<u8>) = conn
            .query_row(
                "SELECT node_version, schema_fingerprint
                 FROM node_metadata WHERE id = 0",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(version, NODE_VERSION);
        assert_eq!(fingerprint, schema_fingerprint().as_slice().to_vec());

        let user_version: u32 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, 0);
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

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            "predates node compatibility metadata",
        );
        let schema_version_after: u64 = conn
            .query_row("PRAGMA schema_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(schema_version_after, schema_version_before);
        let legacy_rows: u64 = conn
            .query_row("SELECT COUNT(*) FROM settlement_info", [], |row| row.get(0))
            .unwrap();
        assert_eq!(legacy_rows, 1);
        let metadata_tables: u64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'node_metadata'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(metadata_tables, 0);
    }

    #[test]
    fn missing_metadata_row_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            "compatibility metadata is missing",
        );
    }

    #[test]
    fn different_node_version_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        let fingerprint = schema_fingerprint();
        apply_schema_with_identity(&conn, "0.0.0-incompatible", fingerprint.as_slice());

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            "database belongs to node version 0.0.0-incompatible",
        );
    }

    #[test]
    fn different_schema_fingerprint_is_refused() {
        let conn = Connection::open_in_memory().unwrap();
        apply_schema_with_identity(&conn, NODE_VERSION, &[0xa5; 32]);

        assert_wipe_error(
            initialize(&conn).unwrap_err(),
            "database schema fingerprint",
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
