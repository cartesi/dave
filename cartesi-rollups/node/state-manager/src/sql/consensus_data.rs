// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use super::error::*;
use crate::{Epoch, Input, InputId};

use rusqlite::{OptionalExtension, params};

//
// Last Processed
//

pub fn update_last_processed_block(conn: &rusqlite::Connection, block: u64) -> Result<()> {
    let previous = last_processed_block(conn)?;

    if previous >= block {
        return Err(PersistentStateAccessError::InconsistentLastProcessed {
            last: previous,
            provided: block,
        });
    }

    conn.execute(
        "UPDATE latest_processed SET block = ?1 WHERE id = 1",
        params![block],
    )?;
    Ok(())
}

pub fn last_processed_block(conn: &rusqlite::Connection) -> Result<u64> {
    Ok(conn.query_row(
        "\
        SELECT block FROM latest_processed WHERE id = 1
        ",
        [],
        |r| r.get(0),
    )?)
}

//
// Inputs
//

fn validate_insert(current: &Option<InputId>, next: &InputId) -> bool {
    match &current {
        Some(i) if !i.validate_next(next) => false,
        None if next.input_index_in_epoch != 0 => false,
        _ => true,
    }
}

pub fn insert_inputs<'a>(
    conn: &rusqlite::Connection,
    inputs: impl Iterator<Item = &'a Input>,
) -> Result<()> {
    let mut inputs = inputs.peekable();
    if inputs.peek().is_none() {
        return Ok(());
    }

    let mut current_input = last_input(conn)?;

    let mut stmt = insert_input_statement(conn)?;
    for input in inputs {
        if !validate_insert(&current_input, &input.id) {
            return Err(PersistentStateAccessError::InconsistentInput {
                previous: current_input,
                provided: input.id.clone(),
            });
        }

        stmt.execute(params![
            input.id.epoch_number,
            input.id.input_index_in_epoch,
            input.data
        ])?;
        current_input = Some(input.id.clone());
    }

    Ok(())
}

fn insert_input_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO inputs (epoch_number, input_index_in_epoch, input) VALUES (?1, ?2, ?3)
        ",
    )?)
}

pub fn last_input(conn: &rusqlite::Connection) -> Result<Option<InputId>> {
    let mut stmt = conn.prepare(
        "\
        SELECT epoch_number, input_index_in_epoch FROM inputs
        ORDER BY epoch_number DESC, input_index_in_epoch DESC
        LIMIT 1
        ",
    )?;

    Ok(stmt
        .query_row([], |row| {
            Ok(InputId {
                epoch_number: row.get(0)?,
                input_index_in_epoch: row.get(1)?,
            })
        })
        .optional()?)
}

pub fn input(conn: &rusqlite::Connection, id: &InputId) -> Result<Option<Input>> {
    let mut stmt = conn.prepare(
        "\
        SELECT * FROM inputs
        WHERE epoch_number = ?1 AND input_index_in_epoch = ?2
        ",
    )?;

    let i = stmt
        .query_row(params![id.epoch_number, id.input_index_in_epoch], |row| {
            Ok(Input {
                id: id.clone(),
                data: row.get(2)?,
            })
        })
        .optional()?;

    Ok(i)
}

pub fn inputs(conn: &rusqlite::Connection, epoch_number: u64) -> Result<Vec<Vec<u8>>> {
    let mut stmt = conn.prepare(
        "\
        SELECT input FROM inputs
        WHERE epoch_number = ?1
        ORDER BY input_index_in_epoch ASC
        ",
    )?;

    let query = stmt.query_map([epoch_number], |r| r.get(0))?;

    let mut res = vec![];
    for row in query {
        res.push(row?);
    }

    Ok(res)
}

pub fn input_count(conn: &rusqlite::Connection, epoch_number: u64) -> Result<u64> {
    Ok(conn.query_row(
        "\
        SELECT MAX(input_index_in_epoch) FROM inputs WHERE epoch_number = ?1
        ",
        [epoch_number],
        |row| {
            let x: Option<u64> = row.get(0)?;
            Ok(x.map(|x: u64| x + 1).unwrap_or(0))
        },
    )?)
}

//
// Epochs
//

pub fn insert_epochs<'a>(
    conn: &rusqlite::Connection,
    epochs: impl Iterator<Item = &'a Epoch>,
) -> Result<()> {
    let mut epochs = epochs.peekable();
    if epochs.peek().is_none() {
        return Ok(());
    }

    let mut next_epoch = epoch_count(conn)?;

    let mut stmt = insert_epoch_statement(conn)?;
    for epoch in epochs {
        if epoch.epoch_number != next_epoch {
            return Err(PersistentStateAccessError::InconsistentEpoch {
                expected: next_epoch,
                provided: epoch.epoch_number,
            });
        }

        stmt.execute(params![
            epoch.epoch_number,
            epoch.input_index_boundary,
            epoch.root_tournament,
            epoch.block_created_number
        ])?;
        next_epoch += 1;
    }
    Ok(())
}

fn insert_epoch_statement(conn: &rusqlite::Connection) -> Result<rusqlite::Statement> {
    Ok(conn.prepare(
        "\
        INSERT INTO epochs (epoch_number, input_index_boundary, root_tournament, block_created_number) VALUES (?1, ?2, ?3, ?4)
        ",
    )?)
}

pub fn last_sealed_epoch(conn: &rusqlite::Connection) -> Result<Option<Epoch>> {
    let mut stmt = conn.prepare(
        "\
        SELECT epoch_number, input_index_boundary, root_tournament, block_created_number FROM epochs
        ORDER BY epoch_number DESC
        LIMIT 1
        ",
    )?;

    Ok(stmt
        .query_row([], |row| {
            Ok(Epoch {
                epoch_number: row.get(0)?,
                input_index_boundary: row.get(1)?,
                root_tournament: row.get(2)?,
                block_created_number: row.get(3)?,
            })
        })
        .optional()?)
}

pub fn epoch(conn: &rusqlite::Connection, epoch_number: u64) -> Result<Option<Epoch>> {
    let mut stmt = conn.prepare(
        "\
        SELECT input_index_boundary, root_tournament, block_created_number FROM epochs
        WHERE epoch_number = ?1
        ",
    )?;

    let e = stmt
        .query_row(params![epoch_number], |row| {
            Ok(Epoch {
                epoch_number,
                input_index_boundary: row.get(0)?,
                root_tournament: row.get(1)?,
                block_created_number: row.get(2)?,
            })
        })
        .optional()?;

    Ok(e)
}

pub fn epoch_count(conn: &rusqlite::Connection) -> Result<u64> {
    Ok(conn.query_row(
        "\
        SELECT MAX(epoch_number) FROM epochs
        ",
        [],
        |row| {
            let x: Option<u64> = row.get(0)?;
            Ok(x.map(|x: u64| x + 1).unwrap_or(0))
        },
    )?)
}

//
// Tests
//

#[cfg(test)]
mod test_helper {
    use crate::sql::migrations;
    use rusqlite::Connection;

    pub fn setup_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        migrations::MIGRATIONS.to_latest(&mut conn).unwrap();
        conn
    }
}

#[cfg(test)]
mod last_processed_block_tests {
    use super::*;

    #[test]
    fn test_last_processed_block() {
        let conn = test_helper::setup_db();

        assert!(matches!(
            update_last_processed_block(&conn, 0),
            Err(PersistentStateAccessError::InconsistentLastProcessed {
                last: 0,
                provided: 0
            })
        ));

        update_last_processed_block(&conn, 1).unwrap();
        assert!(matches!(last_processed_block(&conn), Ok(1)));

        assert!(matches!(
            update_last_processed_block(&conn, 0),
            Err(PersistentStateAccessError::InconsistentLastProcessed {
                last: 1,
                provided: 0
            })
        ));
        assert!(matches!(
            update_last_processed_block(&conn, 1),
            Err(PersistentStateAccessError::InconsistentLastProcessed {
                last: 1,
                provided: 1
            })
        ));

        update_last_processed_block(&conn, 200).unwrap();
        assert!(matches!(last_processed_block(&conn), Ok(200)));
    }
}

#[cfg(test)]
mod inputs_tests {
    use super::*;

    #[test]
    fn test_empty() {
        let conn = test_helper::setup_db();
        assert!(matches!(last_input(&conn), Ok(None)));
        assert!(matches!(input(&conn, &InputId::default()), Ok(None)));
    }

    #[test]
    fn test_insert() {
        let conn = test_helper::setup_db();
        let data = vec![1];

        assert!(matches!(
            insert_inputs(
                &conn,
                [&Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 0
                    },
                    data: data.clone(),
                }]
                .into_iter(),
            ),
            Ok(())
        ));

        assert!(matches!(
            last_input(&conn),
            Ok(Some(InputId {
                epoch_number: 0,
                input_index_in_epoch: 0
            }))
        ));
        assert!(matches!(
            input(
                &conn,
                &InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                },
            ),
            Ok(Some(Input {
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                },
                ..
            }))
        ));

        assert!(matches!(
            insert_inputs(
                &conn,
                [
                    &Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 1
                        },
                        data: data.clone(),
                    },
                    &Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 2
                        },
                        data: data.clone(),
                    },
                    &Input {
                        id: InputId {
                            epoch_number: 1,
                            input_index_in_epoch: 0
                        },
                        data: data.clone(),
                    },
                    &Input {
                        id: InputId {
                            epoch_number: 3,
                            input_index_in_epoch: 0
                        },
                        data: data.clone(),
                    }
                ]
                .into_iter(),
            ),
            Ok(())
        ));
        assert!(matches!(
            last_input(&conn),
            Ok(Some(InputId {
                epoch_number: 3,
                input_index_in_epoch: 0
            }))
        ));
        assert!(matches!(
            input(
                &conn,
                &InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 2
                },
            ),
            Ok(Some(Input {
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 2
                },
                ..
            }))
        ));
    }

    #[test]
    fn test_inconsistent_insert() {
        let conn = test_helper::setup_db();
        let data = vec![1];

        assert!(matches!(
            insert_inputs(
                &conn,
                [&Input {
                    id: InputId {
                        epoch_number: 0,
                        input_index_in_epoch: 1
                    },
                    data: data.clone(),
                }]
                .into_iter(),
            ),
            Err(_)
        ));
        assert!(matches!(
            insert_inputs(
                &conn,
                [&Input {
                    id: InputId {
                        epoch_number: 1,
                        input_index_in_epoch: 1
                    },
                    data: data.clone(),
                }]
                .into_iter(),
            ),
            Err(_)
        ));

        assert!(matches!(last_input(&conn), Ok(None)));
        assert!(matches!(
            input(
                &conn,
                &InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 1
                },
            ),
            Ok(None)
        ));

        assert!(matches!(
            insert_inputs(
                &conn,
                [
                    &Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 0
                        },
                        data: data.clone(),
                    },
                    &Input {
                        id: InputId {
                            epoch_number: 0,
                            input_index_in_epoch: 2
                        },
                        data: data.clone(),
                    },
                ]
                .into_iter(),
            ),
            Err(_)
        ));
        assert!(matches!(
            last_input(&conn),
            Ok(Some(InputId {
                epoch_number: 0,
                input_index_in_epoch: 0
            }))
        ));
        assert!(matches!(
            input(
                &conn,
                &InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                },
            ),
            Ok(Some(Input {
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch: 0
                },
                ..
            }))
        ));
        assert!(matches!(input_count(&conn, 0,), Ok(1)));
    }
}

#[cfg(test)]
mod epochs_tests {
    use super::*;

    #[test]
    fn test_epoch() {
        let conn = test_helper::setup_db();

        assert!(matches!(epoch_count(&conn), Ok(0)));

        assert!(matches!(
            insert_epochs(
                &conn,
                [&Epoch {
                    epoch_number: 1,
                    input_index_boundary: 0,
                    root_tournament: String::new(),
                    block_created_number: 3,
                }]
                .into_iter(),
            ),
            Err(PersistentStateAccessError::InconsistentEpoch {
                expected: 0,
                provided: 1
            })
        ));
        assert!(matches!(epoch_count(&conn), Ok(0)));

        assert!(matches!(
            insert_epochs(
                &conn,
                [&Epoch {
                    epoch_number: 0,
                    input_index_boundary: 0,
                    root_tournament: String::new(),
                    block_created_number: 3,
                }]
                .into_iter(),
            ),
            Ok(())
        ));
        assert!(matches!(epoch_count(&conn), Ok(1)));

        assert!(matches!(
            insert_epochs(
                &conn,
                [&Epoch {
                    epoch_number: 0,
                    input_index_boundary: 0,
                    root_tournament: String::new(),
                    block_created_number: 3,
                }]
                .into_iter(),
            ),
            Err(PersistentStateAccessError::InconsistentEpoch {
                expected: 1,
                provided: 0
            })
        ));
        assert!(matches!(epoch_count(&conn), Ok(1)));

        let x: Vec<_> = (1..128)
            .map(|i| Epoch {
                epoch_number: i,
                input_index_boundary: 0,
                root_tournament: String::new(),
                block_created_number: i * 2,
            })
            .collect();
        assert!(matches!(insert_epochs(&conn, x.iter()), Ok(())));
        assert!(matches!(epoch_count(&conn), Ok(128)));

        assert!(matches!(
            insert_epochs(
                &conn,
                [
                    &Epoch {
                        epoch_number: 128,
                        input_index_boundary: 0,
                        root_tournament: String::new(),
                        block_created_number: 256,
                    },
                    &Epoch {
                        epoch_number: 129,
                        input_index_boundary: 0,
                        root_tournament: String::new(),
                        block_created_number: 258,
                    },
                    &Epoch {
                        epoch_number: 131,
                        input_index_boundary: 0,
                        root_tournament: String::new(),
                        block_created_number: 262,
                    }
                ]
                .into_iter(),
            ),
            Err(PersistentStateAccessError::InconsistentEpoch {
                expected: 130,
                provided: 131
            })
        ));
        assert!(matches!(epoch_count(&conn), Ok(130)));

        let tournament_address = "0x8dA443F84fEA710266C8eB6bC34B71702d033EF2".to_string();
        assert!(matches!(epoch(&conn, 130), Ok(None)));
        assert!(matches!(
            insert_epochs(
                &conn,
                [&Epoch {
                    epoch_number: 130,
                    input_index_boundary: 99,
                    root_tournament: tournament_address,
                    block_created_number: 260,
                }]
                .into_iter(),
            ),
            Ok(())
        ));
        assert!(matches!(
            epoch(&conn, 130),
            Ok(Some(Epoch {
                epoch_number: 130,
                input_index_boundary: 99,
                block_created_number: 260,
                ..
            }))
        ));
    }
}
