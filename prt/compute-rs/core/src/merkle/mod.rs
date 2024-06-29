//! This module exposes a bunch of structures for creating and managing [MerkleTree]. To create a new
//! [MerkleTree] you need to use the [MerkleBuilder] struct. With a MerkleTree you can create a
//! [MerkleProof] and verify it.
//!
//! # Examples
//! ```rust
//! let mut builder = MerkleBuilder::default();
//! builder.add(Digest::zeroed(), 2);
//! builder.add(Digest::zeroed(),0u128.wrapping_sub(2));
//! let merkle = builder.build();
//! assert_eq!(merkle.root_hash(), builder.iterated_merkle(Digest::zeroed(), 128));
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
