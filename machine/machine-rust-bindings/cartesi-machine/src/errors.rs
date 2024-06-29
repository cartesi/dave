// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Error handling for the machine emulator

use crate::utils::from_cstr;
use std::{ffi::c_char, fmt::Display, mem::MaybeUninit};

/// Error returned from machine emulator C API
#[derive(Debug, Clone, thiserror::Error)]
pub struct MachineError {
    code: i32,
    message: Option<String>,
}

impl Display for MachineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Error with code {}: {}",
            self.code as u8,
            self.message.clone().unwrap_or_default()
        )
    }
}

/// Collects an error and cleans the memory. It's used to avoid accidental memory leaks when
/// handling errors using the ownership of [ErrorCollector], the inability to clone it and the
/// [cm_delete_cstring] function.
pub(crate) struct ErrorCollector {
    ptr: MaybeUninit<*mut c_char>,
}

impl ErrorCollector {
    /// Creates a new error collector
    pub fn new() -> Self {
        Self {
            ptr: MaybeUninit::<*mut c_char>::uninit(),
        }
    }

    /// Gets the pointer to the error message
    pub fn as_mut_ptr(&mut self) -> *mut *mut c_char {
        self.ptr.as_mut_ptr()
    }

    /// Collect error from C API
    pub fn collect(self, code: i32) -> Result<(), MachineError> {
        if code == cartesi_machine_sys::CM_ERROR_CM_ERROR_OK as i32 {
            Ok(())
        } else {
            let message = unsafe { from_cstr(*self.ptr.as_ptr()) };
            unsafe { cartesi_machine_sys::cm_delete_cstring(*self.ptr.as_ptr()) };

            Err(MachineError { code, message })
        }
    }
}
