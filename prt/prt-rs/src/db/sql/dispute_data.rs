// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use super::error::*;
use crate::db::Input;

use rusqlite::{params, OptionalExtension};

//
// Inputs
//

pub fn insert_inputs<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Vec<u8>>,
) -> Result<()> {
    let mut stmt = insert_input_statement(&conn)?;
    for (i, input) in inputs.enumerate() {
        stmt.execute(params![i, input])?;
    }

    Ok(())
}

fn insert_input_statement<'a>(conn: &'a rusqlite::Connection) -> Result<rusqlite::Statement<'a>> {
    Ok(conn.prepare(
        "\
        INSERT INTO inputs (input_index, input) VALUES (?1, ?2)
        ",
    )?)
}

pub fn input(conn: &rusqlite::Connection, id: u64) -> Result<Option<Input>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM inputs
        WHERE input_index = ?1
        ",
    )?;

    let i = stmt
        .query_row(params![id], |row| {
            Ok(Input {
                id: id.clone(),
                data: row.get(2)?,
            })
        })
        .optional()?;

    Ok(i)
}

//
// Compute leafs
//

pub fn insert_compute_leafs<'a>(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: u64,
    leafs: impl Iterator<Item = &'a (Vec<u8>, u64)>,
) -> Result<()> {
    let mut stmt = insert_compute_leaf_statement(&conn)?;
    for (i, leaf) in leafs.enumerate() {
        assert!(leaf.1 > 0);
        stmt.execute(params![level, base_cycle, i, leaf.0, leaf.1])?;
    }

    Ok(())
}

fn insert_compute_leaf_statement<'a>(
    conn: &'a rusqlite::Connection,
) -> Result<rusqlite::Statement<'a>> {
    Ok(conn.prepare(
        "\
        INSERT INTO compute_leafs (level, base_cycle, compute_leaf_index, compute_leaf, repetitions) VALUES (?1, ?2, ?3, ?4, ?5)
        ",
    )?)
}

pub fn compute_leafs(
    conn: &rusqlite::Connection,
    level: u64,
    base_cycle: u64,
) -> Result<Vec<(Vec<u8>, u64)>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM compute_leafs
        WHERE level = ?1 AND base_cycle = ?2
        ORDER BY compute_leaf_index ASC
        ",
    )?;

    let query = stmt.query_map([level, base_cycle], |r| {
        Ok((r.get("compute_leaf")?, r.get("repetitions")?))
    })?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

pub fn insert_dispute_data<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Vec<u8>>,
    leafs: impl Iterator<Item = &'a (Vec<u8>, u64)>,
) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    insert_inputs(&tx, inputs)?;
    insert_compute_leafs(&tx, 0, 0, leafs)?;
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

// TODO: add tests
