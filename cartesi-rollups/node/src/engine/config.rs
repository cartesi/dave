// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The write-once configuration: everything contextual the cache rows
//! deliberately do not carry.
//!
//! This is initialization-time state: the node's schema owns the DDL
//! (storage/sql/schema.sql) and `pin` writes the row exactly once
//! at database creation; the dispute module only reads and asserts
//! (`assert_compatible`).

use super::geometry::TournamentGeometry;
use super::structure::Structure;
use crate::merkle::Digest;
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    pub structure: Structure,
    /// The same app, consensus and image can exist on two chains.
    pub chain_id: u64,
    pub app: Vec<u8>,
    /// The consensus the app answered with at initialization: the source
    /// of this store's epochs, inputs, and tournament factory.
    pub consensus: Vec<u8>,
    pub template_hash: Digest,
    pub emulator_version: String,
    /// The deployed level table. Its root stride shapes every stored
    /// window root and settlement hash.
    pub geometry: TournamentGeometry,
}

/// Pins the configuration, once per database; the schema comes from
/// node initialization. Idempotent for an identical configuration; any
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
                "INSERT INTO sling_config VALUES (0, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    config.structure.log2_input_span,
                    config.structure.log2_barch_span,
                    config.structure.log2_uarch_span,
                    config.chain_id,
                    config.app,
                    config.consensus,
                    config.template_hash.slice(),
                    config.emulator_version,
                    config.geometry.encode(),
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
            "SELECT log2_input_span, log2_barch_span, log2_uarch_span, chain_id,
                    app, consensus, template_hash, emulator_version, tournament_levels
             FROM sling_config WHERE id = 0",
            [],
            |row| {
                let structure = Structure {
                    log2_input_span: row.get(0)?,
                    log2_barch_span: row.get(1)?,
                    log2_uarch_span: row.get(2)?,
                };
                Ok((
                    structure,
                    row.get::<_, u64>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, Vec<u8>>(5)?,
                    row.get::<_, Vec<u8>>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                ))
            },
        )
        .optional()?;
    config
        .map(
            |(structure, chain_id, app, consensus, template_hash, emulator_version, levels)| {
                Ok(EngineConfig {
                    structure,
                    chain_id,
                    app,
                    consensus,
                    template_hash: Digest::from_digest(&template_hash)
                        .expect("stored hashes are 32 bytes"),
                    emulator_version,
                    geometry: TournamentGeometry::decode(&levels, &structure)?,
                })
            },
        )
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::geometry::Level;

    #[test]
    fn config_is_write_once() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("cache.db");
        crate::storage::sql::schema::initialize(&Connection::open(&path)?)?;
        let structure = Structure {
            log2_input_span: 1,
            log2_barch_span: 1,
            log2_uarch_span: 2,
        };
        let toy_table = |pairs: &[(u64, u64)]| {
            let levels = pairs
                .iter()
                .map(|&(log2_stride, height)| Level {
                    log2_stride,
                    height,
                })
                .collect();
            TournamentGeometry::new(levels, &structure)
        };
        let config = EngineConfig {
            structure,
            chain_id: 1,
            app: vec![0xaa; 20],
            consensus: vec![0xcc; 20],
            template_hash: Digest::from_digest(&[1u8; 32])?,
            emulator_version: "0.21.0".into(),
            geometry: toy_table(&[(2, 2), (0, 2)])?,
        };
        pin(&Connection::open(&path)?, &config)?;

        // Same config pins again fine (idempotent).
        pin(&Connection::open(&path)?, &config)?;
        assert_eq!(stored(&Connection::open(&path)?)?, Some(config.clone()));

        // Any drift is refused.
        let mut drifted = config.clone();
        drifted.emulator_version = "0.22.0".into();
        assert!(pin(&Connection::open(&path)?, &drifted).is_err());
        let mut drifted = config.clone();
        drifted.chain_id = 11155111;
        assert!(pin(&Connection::open(&path)?, &drifted).is_err());
        let mut drifted = config.clone();
        drifted.consensus = vec![0xdd; 20];
        assert!(pin(&Connection::open(&path)?, &drifted).is_err());
        let mut drifted = config.clone();
        drifted.geometry = toy_table(&[(3, 1), (0, 3)])?;
        assert!(pin(&Connection::open(&path)?, &drifted).is_err());
        Ok(())
    }
}
