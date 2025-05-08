CREATE TABLE IF NOT EXISTS settlement_info (
    epoch_number INTEGER NOT NULL PRIMARY KEY,
    computation_hash BLOB NOT NULL,
    output_merkle BLOB NOT NULL,
    output_proof BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS epochs (
    epoch_number INTEGER NOT NULL PRIMARY KEY,
    input_index_boundary INTEGER NOT NULL,
    root_tournament TEXT NOT NULL,
    block_created_number INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS inputs (
    epoch_number INTEGER NOT NULL,
    input_index_in_epoch INTEGER NOT NULL,
    input BLOB NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);

CREATE TABLE IF NOT EXISTS latest_processed (
    id INTEGER NOT NULL PRIMARY KEY,
    block INTEGER NOT NULL
);
INSERT OR IGNORE INTO latest_processed (id, block)
    VALUES (1, 0);

CREATE TABLE IF NOT EXISTS machine_state_hashes (
    epoch_number INTEGER NOT NULL,
    state_hash_index_in_epoch INTEGER NOT NULL,
    repetitions INTEGER NOT NULL CHECK (repetitions > 0),
    machine_state_hash BLOB NOT NULL,
    PRIMARY KEY (epoch_number, state_hash_index_in_epoch)
);

CREATE TABLE IF NOT EXISTS snapshots (
    epoch_number INTEGER NOT NULL,
    input_index_in_epoch INTEGER NOT NULL,
    path TEXT NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);
