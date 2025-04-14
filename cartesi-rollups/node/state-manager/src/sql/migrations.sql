CREATE TABLE settlement_info (
    epoch_number INTEGER NOT NULL PRIMARY KEY,
    computation_hash BLOB NOT NULL,
    output_merkle BLOB NOT NULL,
    output_proof BLOB NOT NULL
);

CREATE TABLE epochs (
    epoch_number INTEGER NOT NULL PRIMARY KEY,
    input_index_boundary INTEGER NOT NULL,
    root_tournament TEXT NOT NULL,
    block_created_number INTEGER NOT NULL
);

CREATE TABLE inputs (
    epoch_number INTEGER NOT NULL,
    input_index_in_epoch INTEGER NOT NULL,
    input BLOB NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);

CREATE TABLE latest_processed (
    id INTEGER NOT NULL PRIMARY KEY,
    block INTEGER NOT NULL
);
INSERT INTO latest_processed (id, block) VALUES (1, 0);

CREATE TABLE machine_state_hashes (
    epoch_number INTEGER NOT NULL,
    state_hash_index_in_epoch INTEGER NOT NULL,
    repetitions INTEGER NOT NULL,
    machine_state_hash BLOB NOT NULL,
    PRIMARY KEY (epoch_number, state_hash_index_in_epoch)
);

CREATE TABLE snapshots (
    epoch_number INTEGER NOT NULL,
    input_index_in_epoch INTEGER NOT NULL,
    path TEXT NOT NULL,
    PRIMARY KEY (epoch_number, input_index_in_epoch)
);
