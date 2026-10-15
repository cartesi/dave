// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The create-only DDL, its store identity guard, and the source-level
//! discipline tests.

pub mod schema;

#[cfg(test)]
mod discipline;
#[cfg(test)]
pub(crate) mod test_helper;
