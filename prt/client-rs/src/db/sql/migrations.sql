CREATE TABLE inputs (
    input_index INTEGER NOT NULL PRIMARY KEY,
    input BLOB NOT NULL
);

CREATE TABLE compute_leafs (
    level INTEGER NOT NULL,
    base_cycle INTEGER NOT NULL,
    compute_leaf_index INTEGER NOT NULL,
    repetitions INTEGER NOT NULL,
    compute_leaf BLOB NOT NULL,
    PRIMARY KEY (level, base_cycle, compute_leaf_index)
);

CREATE TABLE compute_trees (
    tree_root BLOB NOT NULL,
    tree_leaf_index INTEGER NOT NULL,
    repetitions INTEGER NOT NULL,
    tree_leaf BLOB NOT NULL,
    PRIMARY KEY (tree_root, tree_leaf_index)
);

CREATE TABLE compute_or_rollups (
    id INTEGER NOT NULL PRIMARY KEY,
    handle_rollups INTEGER NOT NULL
);
