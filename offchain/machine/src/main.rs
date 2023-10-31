// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cryptography::{Hasher, KeccakHasher, MerkleTree};
use std::sync::Arc;

fn main() -> () {
    let b = vec![0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let a = KeccakHasher::hash(&b);
    let m: Arc<MerkleTree<KeccakHasher>> = MerkleTree::new_leaf(a);

    ()
}
