//! Tournament integration boundary: a structural event fold, pinned semantic
//! observations, wire-independent domain values, and the transaction sender
//! used by the Hero executor.

mod types;
pub use types::*;

pub mod adapter;
pub mod domain;

mod reader;
pub use reader::*;

mod sender;
pub use sender::*;

pub mod fold;
