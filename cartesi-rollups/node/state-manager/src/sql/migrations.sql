-- (c) Cartesi and individual authors (see AUTHORS)
-- SPDX-License-Identifier: Apache-2.0 (see LICENSE)

CREATE TABLE IF NOT EXISTS settlement_info (
    epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
    computation_hash BLOB NOT NULL,
    final_state BLOB NOT NULL,
    output_merkle BLOB NOT NULL,
    output_proof BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS epochs (
    epoch_number INTEGER NOT NULL PRIMARY KEY CHECK (epoch_number >= 0),
    input_index_boundary INTEGER NOT NULL,
    root_tournament TEXT NOT NULL,
    block_created_number INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS inputs (
    epoch_number INTEGER NOT NULL CHECK (epoch_number >= 0),
    input_index_in_epoch INTEGER NOT NULL,
    input BLOB NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);

CREATE TABLE IF NOT EXISTS latest_processed (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    block INTEGER NOT NULL CHECK (block >= 0)
);
INSERT OR IGNORE INTO latest_processed (id, block)
    VALUES (1, 0);

CREATE TABLE IF NOT EXISTS machine_state_hashes (
    epoch_number INTEGER NOT NULL,
    input_number INTEGER NOT NULL,
    hash_index INTEGER NOT NULL,
    repetitions INTEGER NOT NULL CHECK (repetitions > 0),
    machine_state_hash BLOB NOT NULL,
    PRIMARY KEY (epoch_number, input_number, hash_index)
);

CREATE TABLE IF NOT EXISTS template_machine (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    state_hash BLOB NOT NULL
        UNIQUE
        REFERENCES machine_state_snapshots (state_hash)
        ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS machine_state_snapshots (
    state_hash  BLOB NOT NULL PRIMARY KEY,
    file_path   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS epoch_snapshot_info (
    epoch_number  INTEGER NOT NULL CHECK (epoch_number >= 0),
    input_number  INTEGER NOT NULL CHECK (input_number >= 0),
    state_hash    BLOB NOT NULL,

    PRIMARY KEY (epoch_number, input_number),

    FOREIGN KEY (state_hash)
        REFERENCES machine_state_snapshots (state_hash)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- garbage collect
CREATE TRIGGER IF NOT EXISTS trg_delete_snapshot_files
AFTER DELETE ON machine_state_snapshots
BEGIN
    SELECT fs_delete_dir(OLD.file_path);
END;
