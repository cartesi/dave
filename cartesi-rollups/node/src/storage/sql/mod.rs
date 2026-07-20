// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The DDL and its guards: the single migration (one migration, one
//! DDL path) and the discipline tests that drive every schema
//! trigger to its abort.

pub mod migrations;

#[cfg(test)]
mod discipline;
#[cfg(test)]
pub(crate) mod test_helper;
