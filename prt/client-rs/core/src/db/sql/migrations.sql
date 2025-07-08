CREATE TABLE inputs (
    input_index INTEGER NOT NULL PRIMARY KEY,
    input BLOB NOT NULL
);

CREATE TABLE leafs (
    level INTEGER NOT NULL,
    base_cycle BLOB NOT NULL,
    leaf_index INTEGER NOT NULL,
    repetitions INTEGER NOT NULL,
    leaf BLOB NOT NULL,
    PRIMARY KEY (level, base_cycle, leaf_index)
);
