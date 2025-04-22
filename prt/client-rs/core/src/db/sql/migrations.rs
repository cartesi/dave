use lazy_static::lazy_static;
use rusqlite::Connection;
use rusqlite_migration::{M, Migrations};

lazy_static! {
    pub static ref MIGRATIONS: Migrations<'static> =
        Migrations::new(vec![M::up(include_str!("migrations.sql")),]);
}

pub fn migrate_to_latest(conn: &mut Connection) -> Result<(), rusqlite_migration::Error> {
    MIGRATIONS.to_latest(conn)
}
