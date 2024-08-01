//! This module exposes a bunch of structures for creating and managing [MerkleTree]. To create a new
//! [MerkleTree] you need to use the [MerkleBuilder] struct. With a MerkleTree you can create a
//! [MerkleProof] and verify it.
//!
//! # Examples
//! ```rust
//! use cartesi_dave_merkle::{Digest, MerkleBuilder};
//!
//! let mut builder = MerkleBuilder::default();
//! builder.add_with_repetition(Digest::zeroed(), 2);
//! builder.add_with_repetition(Digest::zeroed(), 6);
//! let merkle = builder.build();
//! ```
//!

mod digest;
pub use digest::*;

mod node;
pub use node::*;

mod tree;
pub use tree::*;

mod tree_builder;
pub use tree_builder::*;
