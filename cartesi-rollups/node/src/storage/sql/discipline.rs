// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Source-level guards on the storage discipline: where the writers may
//! mutate in place or delete, and that schema.sql holds all the DDL.

/// Across the storage module's Rust sources, the only in-place writes
/// advance the watermark and the completion cursor, and the only deletes
/// are the GC statements. A new one must fit its table's class and change
/// this test.
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
        vec![
            ("completion.rs".to_string(), 1),
            ("ingest.rs".to_string(), 1)
        ],
        "only completion and the ingestion watermark write in place"
    );
    assert_eq!(
        delete_hits,
        vec![
            ("advance.rs".to_string(), 1),
            ("snapshots.rs".to_string(), 1)
        ],
        "the GC paths are the only DELETEs: the sling_nodes prune in \
         advance.rs and the boundary release in the boundary store"
    );
}

#[test]
fn schema_file_is_the_only_ddl_source() {
    fn rust_sources(path: &std::path::Path, sources: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_sources(&path, sources);
            } else if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
                sources.push(path);
            }
        }
    }

    let storage_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/storage");
    let markers = [
        ["CREATE", "TABLE"].join(" "),
        ["ALTER", "TABLE"].join(" "),
        ["DROP", "TABLE"].join(" "),
        ["CREATE", "TRIGGER"].join(" "),
        ["DROP", "TRIGGER"].join(" "),
        ["CREATE", "INDEX"].join(" "),
        ["DROP", "INDEX"].join(" "),
        ["CREATE", "VIEW"].join(" "),
        ["DROP", "VIEW"].join(" "),
    ];
    let mut sources = Vec::new();
    rust_sources(&storage_src, &mut sources);

    for path in sources {
        let source = std::fs::read_to_string(&path).unwrap();
        for marker in &markers {
            assert!(
                !source.contains(marker),
                "inline DDL `{marker}` found in {}; keep all DDL in storage/sql/schema.sql",
                path.display()
            );
        }
    }
}
