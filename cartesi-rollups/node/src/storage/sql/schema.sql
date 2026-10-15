-- (c) Cartesi and individual authors (see AUTHORS)
-- SPDX-License-Identifier: Apache-2.0 (see LICENSE)

-- Create-only schema. schema.rs executes this file only for an empty database,
-- then atomically stamps its store format and commitment semantics.

CREATE TABLE node_metadata (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 0),
    store_format INTEGER NOT NULL CHECK (store_format > 0),
    commitment_semantics INTEGER NOT NULL CHECK (commitment_semantics > 0)
) WITHOUT ROWID;

CREATE TABLE settlement_info (
    epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
    computation_hash BLOB NOT NULL
        CHECK (typeof(computation_hash) = 'blob' AND length(computation_hash) = 32),
    final_state BLOB NOT NULL
        CHECK (typeof(final_state) = 'blob' AND length(final_state) = 32),
    iflags_y_data_block BLOB NOT NULL
        CHECK (typeof(iflags_y_data_block) = 'blob' AND length(iflags_y_data_block) = 32),
    iflags_y_siblings BLOB NOT NULL
        CHECK (typeof(iflags_y_siblings) = 'blob' AND length(iflags_y_siblings) = 1888),
    htif_tohost_data_block BLOB NOT NULL
        CHECK (typeof(htif_tohost_data_block) = 'blob' AND length(htif_tohost_data_block) = 32),
    htif_tohost_siblings BLOB NOT NULL
        CHECK (typeof(htif_tohost_siblings) = 'blob' AND length(htif_tohost_siblings) = 1888),
    tx_buffer_data_block BLOB NOT NULL
        CHECK (typeof(tx_buffer_data_block) = 'blob' AND length(tx_buffer_data_block) = 32),
    tx_buffer_siblings BLOB NOT NULL
        CHECK (typeof(tx_buffer_siblings) = 'blob' AND length(tx_buffer_siblings) = 1888)
);

CREATE TABLE epochs (
    epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
    input_index_boundary INTEGER NOT NULL,
    root_tournament TEXT NOT NULL,
    block_created_number INTEGER NOT NULL
);

CREATE TABLE inputs (
    epoch_number INTEGER NOT NULL CHECK (epoch_number >= 0),
    input_index_in_epoch INTEGER NOT NULL,
    input BLOB NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);

CREATE TABLE latest_processed (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    block INTEGER NOT NULL CHECK (block >= 0)
);
INSERT INTO latest_processed (id, block)
    VALUES (1, 0);

CREATE TABLE epoch_completion (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    next_epoch INTEGER NOT NULL
        CHECK (typeof(next_epoch) = 'integer' AND next_epoch >= 0)
) WITHOUT ROWID;
INSERT INTO epoch_completion (id, next_epoch) VALUES (1, 0);

-- Snapshot boundaries: the machine before each input of an epoch, stored
-- at snapshots/0x<state_hash> (paths are derived, never stored, so the
-- data directory can move). Equal states share one directory.
CREATE TABLE epoch_snapshot_info (
    epoch_number  INTEGER NOT NULL CHECK (epoch_number >= 0),
    input_number  INTEGER NOT NULL CHECK (input_number >= 0),
    state_hash    BLOB NOT NULL
        CHECK (typeof(state_hash) = 'blob' AND length(state_hash) = 32),

    PRIMARY KEY (epoch_number, input_number)
);

-- Snapshot directory removal happens in Rust, strictly AFTER the
-- transaction that unreferenced the rows commits (the GC deletes
-- return the orphaned hashes). A crash may orphan a directory, never
-- dangle a row.

-- The sling dispute schema: the quartet cache and its write-once
-- configuration (engine/config.rs). This file is the only DDL path;
-- config::pin writes the row once after schema initialization.

CREATE TABLE sling_config (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    log2_input_span INTEGER NOT NULL,
    log2_barch_span INTEGER NOT NULL,
    log2_uarch_span INTEGER NOT NULL,
    chain_id INTEGER NOT NULL,
    app BLOB NOT NULL,
    consensus BLOB NOT NULL,
    template_hash BLOB NOT NULL,
    emulator_version TEXT NOT NULL,
    tournament_levels TEXT NOT NULL
);

CREATE TABLE sling_nodes (
    epoch INTEGER NOT NULL,
    log2_stride INTEGER NOT NULL,
    height INTEGER NOT NULL,
    shift BLOB NOT NULL,
    hash BLOB NOT NULL,
    PRIMARY KEY (epoch, log2_stride, height, shift)
) WITHOUT ROWID;
