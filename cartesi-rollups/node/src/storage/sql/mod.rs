// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The create-only DDL, its node/schema identity guard, and the discipline
//! tests that drive every schema trigger to its abort.

pub mod schema;

#[cfg(test)]
mod discipline;
#[cfg(test)]
pub(crate) mod test_helper;
