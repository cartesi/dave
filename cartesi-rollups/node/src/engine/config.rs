// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The write-once configuration: everything contextual the cache rows
//! deliberately do not carry.
//!
//! This is migration-time state: the node's migration owns the DDL
//! (storage/sql/migrations.sql) and `pin` writes the row exactly once
//! at database creation; the dispute module only reads and asserts
//! (`assert_compatible`).

use super::structure::Structure;
use crate::merkle::Digest;
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    pub structure: Structure,
    pub app: Vec<u8>,
    pub template_hash: Digest,
    pub emulator_version: String,
}

/// Pins the configuration, once per database; the schema comes from
/// the node migration. Idempotent for an identical configuration; any
/// drift is refused.
pub fn pin(connection: &Connection, config: &EngineConfig) -> Result<()> {
    config.structure.assert_valid();

    match stored(connection)? {
        Some(existing) => ensure!(
            existing == *config,
            "engine database configuration mismatch: stored {:?}, given {:?}",
            existing,
            config
        ),
        None => {
            connection.execute(
                "INSERT INTO sling_config VALUES (0, ?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    config.structure.log2_input_span,
                    config.structure.log2_barch_span,
                    config.structure.log2_uarch_span,
                    config.app,
                    config.template_hash.slice(),
                    config.emulator_version,
                ],
            )?;
        }
    }
    Ok(())
}

/// The dispute module's startup check: the stored pins must match the
/// running engine. Structure and emulator version only - the app and
/// template-hash pins are node-level facts the dispute side cannot
/// derive independently (the epoch snapshot hash differs from the
/// template hash past epoch zero).
pub fn assert_compatible(
    stored: &EngineConfig,
    structure: &Structure,
    emulator_version: &str,
) -> Result<()> {
    ensure!(
        stored.structure == *structure,
        "engine structure mismatch: stored {:?}, running {:?}",
        stored.structure,
        structure
    );
    ensure!(
        stored.emulator_version == emulator_version,
        "emulator version drift: database pinned {}, running {}",
        stored.emulator_version,
        emulator_version
    );
    Ok(())
}

/// The pinned configuration, if the database has one.
pub fn stored(connection: &Connection) -> Result<Option<EngineConfig>> {
    let config = connection
        .query_row(
            "SELECT log2_input_span, log2_barch_span, log2_uarch_span,
                    app, template_hash, emulator_version
             FROM sling_config WHERE id = 0",
            [],
            |row| {
                Ok(EngineConfig {
                    structure: Structure {
                        log2_input_span: row.get(0)?,
                        log2_barch_span: row.get(1)?,
                        log2_uarch_span: row.get(2)?,
                    },
                    app: row.get(3)?,
                    template_hash: Digest::from_digest(&row.get::<_, Vec<u8>>(4)?)
                        .expect("stored hashes are 32 bytes"),
                    emulator_version: row.get(5)?,
                })
            },
        )
        .optional()?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_is_write_once() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("cache.db");
        crate::storage::sql::migrations::migrate_to_latest(&mut Connection::open(&path)?)?;
        let structure = Structure {
            log2_input_span: 1,
            log2_barch_span: 1,
            log2_uarch_span: 2,
        };
        let config = EngineConfig {
            structure,
            app: vec![0xaa; 20],
            template_hash: Digest::from_digest(&[1u8; 32])?,
            emulator_version: "0.20.0".into(),
        };
        pin(&Connection::open(&path)?, &config)?;

        // Same config pins again fine (idempotent).
        pin(&Connection::open(&path)?, &config)?;
        assert_eq!(stored(&Connection::open(&path)?)?, Some(config.clone()));

        // Any drift is refused.
        let mut drifted = config.clone();
        drifted.emulator_version = "0.21.0".into();
        assert!(pin(&Connection::open(&path)?, &drifted).is_err());
        Ok(())
    }
}
