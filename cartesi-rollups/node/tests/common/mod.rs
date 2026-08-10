// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Shared scaffolding for the integration tests.

// The prototype dialect (positioning by shift/mask, its own snapshot
// bookkeeping): deliberately independent of the engine ruler, which is
// exactly what makes it a differential oracle. Retired from
// production; lives on here.
pub mod epoch_data;
pub mod instance;
pub mod machine_error;
pub mod prototype;
