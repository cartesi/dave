//! This module defines the struct [Reader] that is responsible for the reading the states
//! of tournaments; and the struct [Sender] that is responsible for the sending transactions
//! to tournaments

mod config;
pub use config::*;

mod arena;
pub use arena::*;
