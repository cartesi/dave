//! Tournament integration boundary: an event-derived dispute tree, narrow
//! pinned point reads, wire-independent domain values, and the transaction
//! sender used by the Hero executor.

pub mod dispute;
pub mod domain;
pub mod observer;
pub use domain::MatchID;

mod reader;
pub use reader::*;

mod sender;
pub use sender::*;
