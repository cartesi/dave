// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use super::error::*;
use crate::db::compute_state_access::{Input, Leaf};

use alloy::primitives::U256;
use rusqlite::{OptionalExtension, params};

//
// Inputs
//

pub fn insert_inputs<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Input>,
) -> Result<()> {
    let mut stmt = insert_input_statement(conn)?;
    for (i, input) in inputs.enumerate() {
        if stmt.execute(params![i, input.0])? != 1 {
            return Err(ComputeStateAccessError::InsertionFailed {
                description: "input insertion failed".to_owned(),
            });
        }
    }

    Ok(())
}

fn insert_input_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO inputs (input_index, input) VALUES (?1, ?2)
        ",
    )?)
}

pub fn input(conn: &rusqlite::Connection, id: u64) -> Result<Option<Vec<u8>>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM inputs
        WHERE input_index = ?1
        ",
    )?;

    let i = stmt
        .query_row(params![id], |row| row.get("input"))
        .optional()?;

    Ok(i)
}

pub fn inputs(conn: &rusqlite::Connection) -> Result<Vec<Vec<u8>>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM inputs
        ORDER BY input_index ASC
        ",
    )?;

    let query = stmt.query_map([], |r| r.get("input"))?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

//
// Compute leafs
//

pub fn insert_compute_leafs<'a>(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: U256,
    leafs: impl Iterator<Item = &'a Leaf>,
) -> Result<()> {
    let mut stmt = insert_compute_leaf_statement(conn)?;
    for (i, leaf) in leafs.enumerate() {
        assert!(leaf.repetitions > 0);
        if stmt.execute(params![
            level,
            base_cycle.as_le_slice(),
            i,
            leaf.hash,
            leaf.repetitions
        ])? != 1
        {
            return Err(ComputeStateAccessError::InsertionFailed {
                description: "compute leafs insertion failed".to_owned(),
            });
        }
    }

    Ok(())
}

fn insert_compute_leaf_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO compute_leafs (level, base_cycle, compute_leaf_index, compute_leaf, repetitions) VALUES (?1, ?2, ?3, ?4, ?5)
        ",
    )?)
}

pub fn compute_leafs(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: U256,
) -> Result<Vec<(Vec<u8>, u64)>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM compute_leafs
        WHERE level = ?1 AND base_cycle = ?2
        ORDER BY compute_leaf_index ASC
        ",
    )?;

    let query = stmt.query_map(params![level, base_cycle.as_le_slice()], |r| {
        Ok((r.get("compute_leaf")?, r.get("repetitions")?))
    })?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

//
// Compute trees
//

pub fn insert_compute_tree<'a>(
    conn: &rusqlite::Connection,
    tree_root: &[u8],
    tree_leafs: impl Iterator<Item = &'a Leaf>,
) -> Result<()> {
    if compute_tree_count(conn, tree_root)? == 0 {
        let mut stmt = insert_compute_tree_statement(conn)?;
        for (i, leaf) in tree_leafs.enumerate() {
            assert!(leaf.repetitions > 0);
            if stmt.execute(params![tree_root, i, leaf.hash, leaf.repetitions])? != 1 {
                return Err(ComputeStateAccessError::InsertionFailed {
                    description: "compute tree insertion failed".to_owned(),
                });
            }
        }
    }

    Ok(())
}

fn insert_compute_tree_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO compute_trees (tree_root, tree_leaf_index, tree_leaf, repetitions) VALUES (?1, ?2, ?3, ?4)
        ",
    )?)
}

pub fn compute_tree(conn: &rusqlite::Connection, tree_root: &[u8]) -> Result<Vec<(Vec<u8>, u64)>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM compute_trees
        WHERE tree_root = ?1
        ORDER BY tree_leaf_index ASC
        ",
    )?;

    let query = stmt.query_map([tree_root], |r| {
        Ok((r.get("tree_leaf")?, r.get("repetitions")?))
    })?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

pub fn compute_tree_count(conn: &rusqlite::Connection, tree_root: &[u8]) -> Result<u64> {
    Ok(conn.query_row(
        "\
        SELECT count(*) FROM compute_trees
        WHERE tree_root = ?1
        ",
        [tree_root],
        |row| row.get(0),
    )?)
}

//
// Handle rollups
//

fn insert_handle_rollups_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO compute_or_rollups (id, handle_rollups) VALUES (0, ?1)
        ",
    )?)
}

pub fn insert_handle_rollups(conn: &rusqlite::Connection, handle_rollups: bool) -> Result<()> {
    let mut stmt = insert_handle_rollups_statement(conn)?;
    if stmt.execute(params![handle_rollups])? != 1 {
        return Err(ComputeStateAccessError::InsertionFailed {
            description: "rollups operation mode insertion failed".to_owned(),
        });
    }

    Ok(())
}

pub fn handle_rollups(conn: &rusqlite::Connection) -> Result<bool> {
    Ok(conn.query_row(
        "\
        SELECT handle_rollups FROM compute_or_rollups
        WHERE id = 0
        ",
        [],
        |row| row.get(0),
    )?)
}

pub fn insert_compute_data<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Input>,
    leafs: impl Iterator<Item = &'a Leaf>,
) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    insert_inputs(&tx, inputs)?;
    insert_compute_leafs(&tx, 0, U256::ZERO, leafs)?;
    tx.commit()?;

    Ok(())
}

//
// Tests
//

#[cfg(test)]
mod test_helper {
    use crate::db::sql::migrations;
    use rusqlite::Connection;

    pub fn setup_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        migrations::MIGRATIONS.to_latest(&mut conn).unwrap();
        conn
    }
}

#[cfg(test)]
mod inputs_tests {
    use super::*;

    #[test]
    fn test_empty() {
        let conn = test_helper::setup_db();
        assert!(matches!(input(&conn, 0), Ok(None)));
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();
        let data = vec![1];

        assert!(matches!(
            insert_inputs(&conn, [Input(data.clone()), Input(data.clone())].iter(),),
            Ok(())
        ));

        assert!(matches!(input(&conn, 0), Ok(Some(_))));
        assert!(matches!(input(&conn, 1), Ok(Some(_))));

        // overwrite inputs is forbidden
        assert!(insert_inputs(&conn, [Input(data.clone()), Input(data.clone())].iter()).is_err());
    }
}

#[cfg(test)]
mod leafs_tests {
    use super::*;

    #[test]
    fn test_empty() {
        let conn = test_helper::setup_db();
        assert!(matches!(
            compute_leafs(&conn, 0, U256::from(0)).unwrap().len(),
            0
        ));
        assert!(matches!(
            compute_leafs(&conn, 0, U256::from(1)).unwrap().len(),
            0
        ));
        assert!(matches!(
            compute_leafs(&conn, 1, U256::from(1)).unwrap().len(),
            0
        ));
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();
        let data = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            0, 1, 2,
        ];

        assert!(matches!(
            insert_compute_leafs(
                &conn,
                0,
                U256::from(0),
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                ]
                .iter(),
            ),
            Ok(())
        ));
        assert!(matches!(
            compute_leafs(&conn, 0, U256::from(0)).unwrap().len(),
            2
        ));
        // overwrite compute leafs is forbidden
        assert!(
            insert_compute_leafs(
                &conn,
                0,
                U256::from(0),
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                ]
                .iter(),
            )
            .is_err()
        );
        assert!(matches!(
            insert_compute_leafs(
                &conn,
                0,
                U256::from(1),
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                ]
                .iter(),
            ),
            Ok(())
        ));
        assert!(matches!(
            compute_leafs(&conn, 0, U256::from(1)).unwrap().len(),
            2
        ));
        assert!(matches!(
            insert_compute_leafs(
                &conn,
                1,
                U256::from(0),
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                ]
                .iter(),
            ),
            Ok(())
        ));
        assert!(matches!(
            compute_leafs(&conn, 1, U256::from(0)).unwrap().len(),
            2
        ));
    }
}

#[cfg(test)]
mod trees_tests {
    use super::*;

    #[test]
    fn test_empty() {
        let conn = test_helper::setup_db();
        let root = vec![1];
        assert!(matches!(compute_tree(&conn, &root).unwrap().len(), 0));
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();
        let root = vec![1];
        let data = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            0, 1, 2,
        ];

        assert!(matches!(
            insert_compute_tree(
                &conn,
                &root,
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                ]
                .iter(),
            ),
            Ok(())
        ));
        assert!(matches!(compute_tree(&conn, &root).unwrap().len(), 2));

        // tree exists already, skip the transaction
        assert!(matches!(
            insert_compute_tree(
                &conn,
                &root,
                [
                    Leaf {
                        hash: data,
                        repetitions: 1
                    },
                    Leaf {
                        hash: data,
                        repetitions: 2
                    },
                    Leaf {
                        hash: data,
                        repetitions: 3
                    }
                ]
                .iter(),
            ),
            Ok(())
        ));
        // count of tree leafs should remain since the transaction is skipped
        assert!(matches!(compute_tree(&conn, &root).unwrap().len(), 2));
    }
}

#[cfg(test)]
mod compute_or_rollups_tests {
    use super::*;

    #[test]
    fn test_empty() {
        let conn = test_helper::setup_db();
        assert!(handle_rollups(&conn).is_err());
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();

        assert!(insert_handle_rollups(&conn, true).is_ok());
        assert!(matches!(handle_rollups(&conn), Ok(true)));
        // compute_or_rollups can only be set once
        assert!(insert_handle_rollups(&conn, true).is_err());
        assert!(matches!(handle_rollups(&conn), Ok(true)));
    }
}
