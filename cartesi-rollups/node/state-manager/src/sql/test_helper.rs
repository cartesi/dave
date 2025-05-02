// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::sql::migrations;
use rusqlite::Connection;

pub fn setup_db() -> Connection {
    let mut conn = Connection::open_in_memory().unwrap();
    migrations::MIGRATIONS.to_latest(&mut conn).unwrap();
    conn
}
