CREATE TABLE inputs (
    input_index INTEGER NOT NULL PRIMARY KEY,
    input BLOB NOT NULL
);

CREATE TABLE compute_leafs (
    level INTEGER NOT NULL,
    base_cycle BLOB NOT NULL,
    compute_leaf_index INTEGER NOT NULL,
    repetitions INTEGER NOT NULL,
    compute_leaf BLOB NOT NULL,
    PRIMARY KEY (level, base_cycle, compute_leaf_index)
);
