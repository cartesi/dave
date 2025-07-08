// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use super::error::*;
use crate::db::dispute_state_access::{Input, Leaf};

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
            return Err(DisputeStateAccessError::InsertionFailed {
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

pub fn insert_leafs<'a>(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: U256,
    leafs: impl Iterator<Item = &'a Leaf>,
) -> Result<()> {
    let leafs_count = leafs_count(conn, level, base_cycle)?;
    let mut stmt = insert_leaf_statement(conn)?;
    for (i, leaf) in leafs.enumerate() {
        assert!(leaf.repetitions > 0);
        if stmt.execute(params![
            level,
            base_cycle.as_le_slice(),
            i + leafs_count,
            leaf.hash,
            leaf.repetitions
        ])? != 1
        {
            return Err(DisputeStateAccessError::InsertionFailed {
                description: "compute leafs insertion failed".to_owned(),
            });
        }
    }

    Ok(())
}

fn insert_leaf_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO leafs (level, base_cycle, leaf_index, leaf, repetitions) VALUES (?1, ?2, ?3, ?4, ?5)
        ",
    )?)
}

pub fn leafs(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: U256,
) -> Result<Vec<(Vec<u8>, u64)>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM leafs
        WHERE level = ?1 AND base_cycle = ?2
        ORDER BY leaf_index ASC
        ",
    )?;

    let query = stmt.query_map(params![level, base_cycle.as_le_slice()], |r| {
        Ok((r.get("leaf")?, r.get("repetitions")?))
    })?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

pub fn leafs_count(conn: &rusqlite::Connection, level: u64, base_cycle: U256) -> Result<usize> {
    Ok(conn.query_row(
        "\
        SELECT count(*) FROM leafs
        WHERE level = ?1 AND base_cycle = ?2
        ",
        params![level, base_cycle.as_le_slice()],
        |row| row.get(0).map(|i: u64| i as usize),
    )?)
}

pub fn insert_compute_data<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Input>,
    leafs: impl Iterator<Item = &'a Leaf>,
) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    insert_inputs(&tx, inputs)?;
    insert_leafs(&tx, 0, U256::ZERO, leafs)?;
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
        assert!(matches!(leafs(&conn, 0, U256::from(0)).unwrap().len(), 0));
        assert!(matches!(leafs(&conn, 0, U256::from(1)).unwrap().len(), 0));
        assert!(matches!(leafs(&conn, 1, U256::from(1)).unwrap().len(), 0));
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();
        let data = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            0, 1, 2,
        ];

        assert!(matches!(
            insert_leafs(
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
        assert!(matches!(leafs(&conn, 0, U256::from(0)).unwrap().len(), 2));
        // compute leafs can be accumulated
        assert!(matches!(
            insert_leafs(
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
        assert!(matches!(leafs(&conn, 0, U256::from(0)).unwrap().len(), 4));
        assert!(matches!(
            insert_leafs(
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
        assert!(matches!(leafs(&conn, 0, U256::from(1)).unwrap().len(), 2));
        assert!(matches!(
            insert_leafs(
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
        assert!(matches!(leafs(&conn, 1, U256::from(0)).unwrap().len(), 2));
    }
}
