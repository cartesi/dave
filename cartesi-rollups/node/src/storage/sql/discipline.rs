// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The storage discipline tests enforce four mutation classes. The
//! schema's trigger layer must refuse writes outside them even
//! when they arrive through a raw connection that bypasses the Rust
//! checks. Each test drives one trigger to its RAISE(ABORT).

use rusqlite::{Connection, params};

/// A migrated schema on a raw connection - no machine image, no
/// genesis seeding; the trigger layer is pure DDL.
fn migrated_conn() -> (tempfile::TempDir, Connection) {
    let dir = tempfile::tempdir().unwrap();
    let mut conn = Connection::open(dir.path().join("db.sqlite3")).unwrap();
    super::migrations::migrate_to_latest(&mut conn).unwrap();
    (dir, conn)
}

fn expect_abort(result: rusqlite::Result<usize>, message_fragment: &str) {
    let err = result.expect_err("the trigger should refuse this write");
    let text = err.to_string();
    assert!(
        text.contains(message_fragment),
        "expected abort containing `{message_fragment}`, got `{text}`"
    );
}

//
// epochs: append-only, dense from 0
//

#[test]
fn epochs_refuse_gaps_updates_and_deletes() {
    let (_dir, conn) = migrated_conn();
    let insert = "INSERT INTO epochs VALUES (?1, 0, '0x00', 0)";

    expect_abort(conn.execute(insert, params![1]), "densely from 0");
    conn.execute(insert, params![0]).unwrap();
    conn.execute(insert, params![1]).unwrap();
    expect_abort(conn.execute(insert, params![3]), "densely from 0");

    expect_abort(
        conn.execute("UPDATE epochs SET block_created_number = 9", []),
        "append-only",
    );
    expect_abort(conn.execute("DELETE FROM epochs", []), "append-only");
}

//
// inputs: append-only, advancing per InputId::validate_next
//

#[test]
fn inputs_refuse_non_contiguous_coordinates() {
    let (_dir, conn) = migrated_conn();
    let insert = "INSERT INTO inputs VALUES (?1, ?2, x'00')";

    // the first input of the database must open an epoch
    expect_abort(conn.execute(insert, params![0, 1]), "validate_next");

    conn.execute(insert, params![0, 0]).unwrap();
    conn.execute(insert, params![0, 1]).unwrap();

    // a gap within the epoch
    expect_abort(conn.execute(insert, params![0, 3]), "validate_next");
    // a later epoch must restart at 0
    expect_abort(conn.execute(insert, params![2, 1]), "validate_next");
    // going backwards
    expect_abort(conn.execute(insert, params![0, 0]), "validate_next");

    // skipping an inputless epoch is legal
    conn.execute(insert, params![2, 0]).unwrap();
}

#[test]
fn inputs_refuse_updates_and_deletes() {
    let (_dir, conn) = migrated_conn();
    conn.execute("INSERT INTO inputs VALUES (0, 0, x'00')", [])
        .unwrap();
    expect_abort(
        conn.execute("UPDATE inputs SET input = x'01'", []),
        "append-only",
    );
    expect_abort(conn.execute("DELETE FROM inputs", []), "append-only");
}

//
// latest_processed: monotonic watermark singleton
//

#[test]
fn latest_processed_only_rises_and_never_disappears() {
    let (_dir, conn) = migrated_conn();
    let update = "UPDATE latest_processed SET block = ?1 WHERE id = 1";

    conn.execute(update, params![10]).unwrap();
    // equal is a no-op raise, not a violation
    conn.execute(update, params![10]).unwrap();
    expect_abort(conn.execute(update, params![9]), "only rises");
    expect_abort(
        conn.execute("DELETE FROM latest_processed", []),
        "permanent singleton",
    );
}

//
// settlement_info: write-once cell per epoch
//

#[test]
fn settlement_info_is_write_once() {
    let (_dir, conn) = migrated_conn();
    conn.execute(
        "INSERT INTO settlement_info VALUES (0, x'00', x'01', x'02', x'03')",
        [],
    )
    .unwrap();
    expect_abort(
        conn.execute("UPDATE settlement_info SET computation_hash = x'ff'", []),
        "write-once",
    );
    expect_abort(
        conn.execute("DELETE FROM settlement_info", []),
        "write-once",
    );
}

//
// sling_config: write-once cell
//

#[test]
fn sling_config_is_write_once() {
    let (_dir, conn) = migrated_conn();
    conn.execute(
        "INSERT INTO sling_config VALUES (0, 24, 27, 20, x'00', x'01', 'v')",
        [],
    )
    .unwrap();
    expect_abort(
        conn.execute("UPDATE sling_config SET emulator_version = 'w'", []),
        "write-once",
    );
    expect_abort(conn.execute("DELETE FROM sling_config", []), "write-once");
}

//
// template_machine: write-once cell with verify on re-insert
//

#[test]
fn template_machine_absorbs_identical_and_refuses_drift() {
    let (_dir, conn) = migrated_conn();
    // satisfy the FK on machine_state_snapshots
    conn.execute(
        "INSERT INTO machine_state_snapshots VALUES (?1, '/a')",
        params![[1u8; 32]],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO machine_state_snapshots VALUES (?1, '/b')",
        params![[2u8; 32]],
    )
    .unwrap();

    let insert = "INSERT OR IGNORE INTO template_machine VALUES (1, ?1)";
    conn.execute(insert, params![[1u8; 32]]).unwrap();
    // identical re-insert absorbed; INSERT OR IGNORE previously
    // absorbed disagreement too - the trigger closes exactly that
    conn.execute(insert, params![[1u8; 32]]).unwrap();
    expect_abort(
        conn.execute(insert, params![[2u8; 32]]),
        "disagrees with its stored row",
    );
    expect_abort(
        conn.execute(
            "UPDATE template_machine SET state_hash = ?1",
            params![[2u8; 32]],
        ),
        "write-once",
    );
    expect_abort(
        conn.execute("DELETE FROM template_machine", []),
        "write-once",
    );
}

//
// sling_nodes: the collision tripwire; prune stays legal
//

#[test]
fn sling_nodes_collision_aborts_in_the_database_itself() {
    let (_dir, conn) = migrated_conn();
    let insert = "INSERT INTO sling_nodes VALUES (?1, ?2, ?3, ?4, ?5)
                  ON CONFLICT DO NOTHING";

    conn.execute(insert, params![0, 44, 3, [0u8; 32], [7u8; 32]])
        .unwrap();
    // determinism makes duplicates benign
    conn.execute(insert, params![0, 44, 3, [0u8; 32], [7u8; 32]])
        .unwrap();
    // a disagreeing hash at the same coordinate is the loudest signal
    expect_abort(
        conn.execute(insert, params![0, 44, 3, [0u8; 32], [8u8; 32]]),
        "node cache collision",
    );
    expect_abort(
        conn.execute("UPDATE sling_nodes SET hash = x'00'", []),
        "write-once",
    );
    // settled-epoch prune is the blessed delete
    conn.execute("DELETE FROM sling_nodes WHERE epoch <= 0", [])
        .unwrap();
}

//
// epoch_snapshot_info / machine_state_snapshots: prunable derived
// stores with write-once-verify coordinates
//

#[test]
fn snapshot_index_verifies_replays_and_refuses_updates() {
    let (_dir, conn) = migrated_conn();
    conn.execute(
        "INSERT INTO machine_state_snapshots VALUES (?1, '/a')",
        params![[1u8; 32]],
    )
    .unwrap();
    let insert = "INSERT INTO epoch_snapshot_info VALUES (0, 0, ?1)
                  ON CONFLICT DO NOTHING";
    conn.execute(insert, params![[1u8; 32]]).unwrap();
    conn.execute(insert, params![[1u8; 32]]).unwrap();
    expect_abort(
        conn.execute(insert, params![[9u8; 32]]),
        "nondeterminism or corruption",
    );
    expect_abort(
        conn.execute("UPDATE epoch_snapshot_info SET input_number = 5", []),
        "write-once",
    );
}

#[test]
fn cas_rows_pin_their_path() {
    let (_dir, conn) = migrated_conn();
    let insert = "INSERT INTO machine_state_snapshots VALUES (?1, ?2)
                  ON CONFLICT DO NOTHING";
    conn.execute(insert, params![[1u8; 32], "/a"]).unwrap();
    conn.execute(insert, params![[1u8; 32], "/a"]).unwrap();
    expect_abort(
        conn.execute(insert, params![[1u8; 32], "/b"]),
        "different path",
    );
    expect_abort(
        conn.execute("UPDATE machine_state_snapshots SET file_path = '/c'", []),
        "write-once",
    );
}

//
// tournament_events: prunable derived store, gated by its watermark
// (fold phase 2)
//

#[test]
fn tournament_events_stay_behind_the_watermark_and_final() {
    let (_dir, conn) = migrated_conn();
    let insert = "INSERT INTO tournament_events VALUES ('aa', ?1, 0, x'00')";

    // No watermark row yet: nothing is finalized, nothing may land.
    expect_abort(
        conn.execute(insert, params![5]),
        "outrun the finalized watermark",
    );

    conn.execute(
        "INSERT INTO tournament_events_watermark VALUES ('aa', 10)",
        [],
    )
    .unwrap();
    conn.execute(insert, params![5]).unwrap();
    conn.execute(insert, params![10]).unwrap();
    expect_abort(
        conn.execute(insert, params![11]),
        "outrun the finalized watermark",
    );

    expect_abort(
        conn.execute("UPDATE tournament_events SET raw_log = x'01'", []),
        "final",
    );
    // Prunable derived store: the settled-epoch GC deletes freely.
    conn.execute(
        "DELETE FROM tournament_events WHERE root_tournament = 'aa'",
        [],
    )
    .unwrap();
}

#[test]
fn tournament_events_watermark_only_rises() {
    let (_dir, conn) = migrated_conn();
    conn.execute(
        "INSERT INTO tournament_events_watermark VALUES ('aa', 10)",
        [],
    )
    .unwrap();
    conn.execute(
        "UPDATE tournament_events_watermark SET finalized_block = 12
         WHERE root_tournament = 'aa'",
        [],
    )
    .unwrap();
    expect_abort(
        conn.execute(
            "UPDATE tournament_events_watermark SET finalized_block = 11
             WHERE root_tournament = 'aa'",
            [],
        ),
        "only rises",
    );
    // Pruned with its dispute.
    conn.execute(
        "DELETE FROM tournament_events_watermark WHERE root_tournament = 'aa'",
        [],
    )
    .unwrap();
}

/// The grep-level half of the taxonomy check (the plan accepts it as
/// such): across the storage module's Rust sources, the only SQL
/// UPDATEs are the two watermark raises, and the only DELETEs are the
/// GC statements. New mutations must either fit an existing class or
/// change this test alongside a schema trigger.
#[test]
fn mutation_taxonomy_holds_at_source_level() {
    let storage_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/storage");

    let mut update_hits: Vec<(String, usize)> = Vec::new();
    let mut delete_hits: Vec<(String, usize)> = Vec::new();

    for entry in std::fs::read_dir(&storage_src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let source = std::fs::read_to_string(&path).unwrap();

        let updates = source.matches("UPDATE").count();
        if updates > 0 {
            update_hits.push((name.clone(), updates));
        }
        let deletes = source.matches("DELETE FROM").count();
        if deletes > 0 {
            delete_hits.push((name, deletes));
        }
    }

    update_hits.sort();
    delete_hits.sort();
    assert_eq!(
        update_hits,
        vec![("dispute.rs".to_string(), 1), ("ingest.rs".to_string(), 1)],
        "the two watermark upserts (tournament events; latest processed block) \
         are the only UPDATEs in the storage module"
    );
    assert_eq!(
        delete_hits,
        vec![
            ("advance.rs".to_string(), 4),
            ("snapshots.rs".to_string(), 2)
        ],
        "the GC paths are the only DELETEs: the old-epoch boundary, \
         sling_nodes, and tournament-event prunes in advance.rs; the gap \
         prune and the unreferenced-snapshot sweep in the boundary store"
    );
}
