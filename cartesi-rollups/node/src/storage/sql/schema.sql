-- (c) Cartesi and individual authors (see AUTHORS)
-- SPDX-License-Identifier: Apache-2.0 (see LICENSE)

-- Create-only schema. schema.rs executes this file only for an empty database,
-- then atomically stamps its raw Keccak fingerprint and the node version.

CREATE TABLE node_metadata (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 0),
    node_version TEXT NOT NULL CHECK (node_version <> ''),
    schema_fingerprint BLOB NOT NULL
        CHECK (
            typeof(schema_fingerprint) = 'blob'
            AND length(schema_fingerprint) = 32
        )
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

CREATE TABLE template_machine (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    state_hash BLOB NOT NULL
        UNIQUE
        REFERENCES machine_state_snapshots (state_hash)
        ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE TABLE machine_state_snapshots (
    state_hash  BLOB NOT NULL PRIMARY KEY,
    file_path   TEXT NOT NULL
);

CREATE TABLE epoch_snapshot_info (
    epoch_number  INTEGER NOT NULL CHECK (epoch_number >= 0),
    input_number  INTEGER NOT NULL CHECK (input_number >= 0),
    state_hash    BLOB NOT NULL,

    PRIMARY KEY (epoch_number, input_number),

    FOREIGN KEY (state_hash)
        REFERENCES machine_state_snapshots (state_hash)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- Snapshot directory removal happens in Rust, strictly AFTER the
-- transaction that unreferenced the rows commits (the GC deletes
-- return the orphaned paths). A trigger used to delete directories
-- mid-transaction, which inverted the crash invariant: a rollback or
-- a mid-statement crash restored rows whose directories were already
-- gone. The rule is: a crash may orphan a directory, never dangle a
-- row.

-- The sling dispute schema: the quartet cache and its write-once
-- configuration (sling/config.rs). This file is the only DDL path;
-- config::pin writes the row once after schema initialization.

CREATE TABLE sling_config (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    log2_input_span INTEGER NOT NULL,
    log2_barch_span INTEGER NOT NULL,
    log2_uarch_span INTEGER NOT NULL,
    app BLOB NOT NULL,
    template_hash BLOB NOT NULL,
    emulator_version TEXT NOT NULL
);

CREATE TABLE sling_nodes (
    epoch INTEGER NOT NULL,
    log2_stride INTEGER NOT NULL,
    height INTEGER NOT NULL,
    shift BLOB NOT NULL,
    hash BLOB NOT NULL,
    PRIMARY KEY (epoch, log2_stride, height, shift)
) WITHOUT ROWID;

-- The dispute event log: raw chain logs of
-- every tournament the dispute discovered, persisted once FINALIZED,
-- keyed for replay in chain order (block, then log index). The tail
-- past the watermark is never stored - it is scratch, refetched each
-- tick; persisted events are final by definition, which is the whole
-- reorg stance. Raw logs (JSON) rather than decoded events keep the
-- current contract ABI as the decode authority and let the fused reader
-- reconstruct its recursive model after restart. Prunable derived store:
-- refetchable from the chain, deleted with the settled epoch.
CREATE TABLE tournament_events (
    root_tournament TEXT NOT NULL,  -- encode_hex, as epochs stores it
    block_number INTEGER NOT NULL,
    log_index INTEGER NOT NULL,
    raw_log BLOB NOT NULL,
    PRIMARY KEY (root_tournament, block_number, log_index)
) WITHOUT ROWID;

-- Monotonic watermark: the highest finalized block whose events are
-- fully persisted for this dispute. Advances every tick, events or
-- not, so the live tail refetch stays bounded.
CREATE TABLE tournament_events_watermark (
    root_tournament TEXT NOT NULL PRIMARY KEY,
    finalized_block INTEGER NOT NULL
) WITHOUT ROWID;

-- The invariant layer.
--
-- Every write belongs to one of four classes: append-only log,
-- write-once cell (equal rewrites absorbed, disagreements fatal),
-- monotonic watermark, or prunable derived store. The triggers below
-- make the database itself refuse writes outside that taxonomy, so
-- the discipline holds even against a buggy writer or a raw
-- connection. The Rust writer keeps its own checks; these are
-- defense-in-depth, not the primary line.

-- node_metadata: the immutable identity of the node and schema that created
-- this rebuildable store.

CREATE TRIGGER trg_node_metadata_no_update
BEFORE UPDATE ON node_metadata
BEGIN
    SELECT RAISE(ABORT, 'node_metadata is write-once');
END;

CREATE TRIGGER trg_node_metadata_no_delete
BEFORE DELETE ON node_metadata
BEGIN
    SELECT RAISE(ABORT, 'node_metadata is write-once');
END;

-- epochs: append-only log, dense from 0 (mirrors insert_epochs).

CREATE TRIGGER trg_epochs_dense
BEFORE INSERT ON epochs
FOR EACH ROW
WHEN NEW.epoch_number != (SELECT COALESCE(MAX(epoch_number) + 1, 0) FROM epochs)
BEGIN
    SELECT RAISE(ABORT, 'epochs must be inserted densely from 0');
END;

CREATE TRIGGER trg_epochs_no_update
BEFORE UPDATE ON epochs
BEGIN
    SELECT RAISE(ABORT, 'epochs is an append-only log');
END;

CREATE TRIGGER trg_epochs_no_delete
BEFORE DELETE ON epochs
BEGIN
    SELECT RAISE(ABORT, 'epochs is an append-only log');
END;

-- inputs: append-only log, advancing per InputId::validate_next -
-- next index within the last epoch, or index 0 in any later epoch
-- (epochs with no inputs are skipped, not padded).

CREATE TRIGGER trg_inputs_contiguous
BEFORE INSERT ON inputs
FOR EACH ROW
WHEN NOT (
    (NOT EXISTS (SELECT 1 FROM inputs) AND NEW.input_index_in_epoch = 0)
    OR EXISTS (
        SELECT 1 FROM (
            SELECT epoch_number AS e, input_index_in_epoch AS i
            FROM inputs
            ORDER BY epoch_number DESC, input_index_in_epoch DESC
            LIMIT 1
        )
        WHERE (NEW.epoch_number = e AND NEW.input_index_in_epoch = i + 1)
           OR (NEW.epoch_number > e AND NEW.input_index_in_epoch = 0)
    )
)
BEGIN
    SELECT RAISE(ABORT, 'inputs must advance per InputId::validate_next');
END;

CREATE TRIGGER trg_inputs_no_update
BEFORE UPDATE ON inputs
BEGIN
    SELECT RAISE(ABORT, 'inputs is an append-only log');
END;

CREATE TRIGGER trg_inputs_no_delete
BEFORE DELETE ON inputs
BEGIN
    SELECT RAISE(ABORT, 'inputs is an append-only log');
END;

-- latest_processed: monotonic watermark on a permanent singleton.

CREATE TRIGGER trg_latest_processed_monotone
BEFORE UPDATE OF block ON latest_processed
FOR EACH ROW
WHEN NEW.block < OLD.block
BEGIN
    SELECT RAISE(ABORT, 'latest_processed only rises');
END;

CREATE TRIGGER trg_latest_processed_no_delete
BEFORE DELETE ON latest_processed
BEGIN
    SELECT RAISE(ABORT, 'latest_processed is a permanent singleton');
END;

-- settlement_info: write-once cell per epoch.

CREATE TRIGGER trg_settlement_info_no_update
BEFORE UPDATE ON settlement_info
BEGIN
    SELECT RAISE(ABORT, 'settlement_info is write-once per epoch');
END;

CREATE TRIGGER trg_settlement_info_no_delete
BEFORE DELETE ON settlement_info
BEGIN
    SELECT RAISE(ABORT, 'settlement_info is write-once per epoch');
END;

-- sling_config: write-once cell (config::pin absorbs an identical
-- re-pin and refuses drift in Rust; the triggers close the raw path).

CREATE TRIGGER trg_sling_config_no_update
BEFORE UPDATE ON sling_config
BEGIN
    SELECT RAISE(ABORT, 'sling_config is write-once');
END;

CREATE TRIGGER trg_sling_config_no_delete
BEFORE DELETE ON sling_config
BEGIN
    SELECT RAISE(ABORT, 'sling_config is write-once');
END;

-- template_machine: write-once cell. INSERT OR IGNORE previously
-- absorbed a DISAGREEING rewrite silently; the verify trigger closes
-- that (equal rewrites still absorb via the conflict clause).

CREATE TRIGGER trg_template_machine_write_once_verify
BEFORE INSERT ON template_machine
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM template_machine
    WHERE id = NEW.id AND state_hash != NEW.state_hash
)
BEGIN
    SELECT RAISE(ABORT, 'template_machine disagrees with its stored row');
END;

CREATE TRIGGER trg_template_machine_no_update
BEFORE UPDATE ON template_machine
BEGIN
    SELECT RAISE(ABORT, 'template_machine is write-once');
END;

CREATE TRIGGER trg_template_machine_no_delete
BEFORE DELETE ON template_machine
BEGIN
    SELECT RAISE(ABORT, 'template_machine is write-once');
END;

-- sling_nodes: append-only write-once-verify (the nondeterminism
-- tripwire; message and semantics mirror Storage::insert_quartet_nodes)
-- plus settled-epoch prune (gc_old_epochs deletes epochs at least two
-- behind the live dispute - DaveConsensus settles epoch N before
-- sealing N + 1, so those tournaments are finished).

CREATE TRIGGER trg_sling_nodes_collision
BEFORE INSERT ON sling_nodes
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM sling_nodes
    WHERE epoch = NEW.epoch AND log2_stride = NEW.log2_stride
      AND height = NEW.height AND shift = NEW.shift
      AND hash != NEW.hash
)
BEGIN
    SELECT RAISE(ABORT, 'node cache collision: nondeterminism or version drift');
END;

CREATE TRIGGER trg_sling_nodes_no_update
BEFORE UPDATE ON sling_nodes
BEGIN
    SELECT RAISE(ABORT, 'sling_nodes rows are write-once');
END;

-- epoch_snapshot_info: prunable derived store with write-once-verify
-- replay semantics on the boundary coordinate (a reprocessed boundary
-- must reproduce the same machine state).

CREATE TRIGGER trg_epoch_snapshot_info_write_once_verify
BEFORE INSERT ON epoch_snapshot_info
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM epoch_snapshot_info
    WHERE epoch_number = NEW.epoch_number
      AND input_number = NEW.input_number
      AND state_hash != NEW.state_hash
)
BEGIN
    SELECT RAISE(ABORT, 'snapshot boundary disagrees with its stored row: nondeterminism or corruption');
END;

CREATE TRIGGER trg_epoch_snapshot_info_no_update
BEFORE UPDATE ON epoch_snapshot_info
BEGIN
    SELECT RAISE(ABORT, 'epoch_snapshot_info rows are write-once (prune-only)');
END;

-- machine_state_snapshots: content-addressed store; the path is a
-- pure function of the hash, so a re-registration at a different
-- path is corruption.

CREATE TRIGGER trg_snapshots_cas_immutable
BEFORE INSERT ON machine_state_snapshots
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM machine_state_snapshots
    WHERE state_hash = NEW.state_hash AND file_path != NEW.file_path
)
BEGIN
    SELECT RAISE(ABORT, 'content-addressed snapshot re-registered at a different path');
END;

CREATE TRIGGER trg_snapshots_no_update
BEFORE UPDATE ON machine_state_snapshots
BEGIN
    SELECT RAISE(ABORT, 'machine_state_snapshots rows are write-once (prune-only)');
END;

-- tournament_events: prunable derived store (chain-refetchable,
-- deleted with the settled epoch); rows are final once written, and
-- nothing past a dispute's watermark may be stored - the tail is
-- scratch by design.

CREATE TRIGGER trg_tournament_events_no_update
BEFORE UPDATE ON tournament_events
BEGIN
    SELECT RAISE(ABORT, 'tournament_events rows are final (prune-only)');
END;

CREATE TRIGGER trg_tournament_events_finalized_only
BEFORE INSERT ON tournament_events
FOR EACH ROW
WHEN NEW.block_number > COALESCE((
    SELECT finalized_block FROM tournament_events_watermark
    WHERE root_tournament = NEW.root_tournament
), -1)
BEGIN
    SELECT RAISE(ABORT, 'tournament_events must not outrun the finalized watermark');
END;

-- tournament_events_watermark: monotonic; pruned with its dispute.

CREATE TRIGGER trg_tournament_events_watermark_monotone
BEFORE UPDATE OF finalized_block ON tournament_events_watermark
FOR EACH ROW
WHEN NEW.finalized_block < OLD.finalized_block
BEGIN
    SELECT RAISE(ABORT, 'tournament_events_watermark only rises');
END;
