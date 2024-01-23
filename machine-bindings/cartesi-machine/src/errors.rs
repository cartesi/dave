//! Error handling for the machine emulator

use std::{ffi::c_char, fmt::Display};

fn c_char_to_string(c_char: *const c_char) -> &'static str {
    if c_char.is_null() {
        ""
    } else {
        unsafe { std::ffi::CStr::from_ptr(c_char).to_str().unwrap() }
    }
}

/// Error codes returned from machine emulator C API
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    // Logic errors
    InvalidArgument = 1,
    DomainError,
    LengthError,
    OutOfRange,
    LogicError,

    // Bad optional access error
    BadOptionalAccess,

    // Runtime errors
    RuntimeError,
    RangeError,
    OverflowError,
    UnderflowError,
    RegexError,
    SystemIosBaseFailure,
    FilesystemError,
    AtomicTxError,
    NonexistingLocalTime,
    AmbigousLocalTime,
    FormatError,

    // Other errors
    BadTypeid,
    BadCast,
    BadAnyCast,
    BadWeakPtr,
    BadFunctionCall,
    BadAlloc,
    BadArrayNewLength,
    BadException,
    BadVariantAccess,
    Exception,

    // C API Errors
    Unknown,
}

/// Error returned from machine emulator C API
pub struct MachineError {
    code: ErrorCode,
    message: *const c_char
}

impl Drop for MachineError {
    fn drop(&mut self) {
        unsafe { cartesi_machine_sys::cm_delete_cstring(self.message) };
    }
}

impl Display for MachineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = c_char_to_string(self.message);
        write!(f, "Error {:?}: {}", self.code as u8, message)
    }
}

impl std::fmt::Debug for MachineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = c_char_to_string(self.message);
        f.debug_struct("MachineError")
            .field("code", &self.code)
            .field("message", &message)
            .finish()
    }
}

pub struct ErrorCollector {
    ptr: *mut c_char
}

impl ErrorCollector {
    /// Creates a new error collector
    pub fn new() -> Self {
        Self {
            ptr: std::ptr::null_mut()
        }
    }

    /// Gets the pointer to the error message
    pub fn as_mut_ptr(&mut self) -> *mut c_char {
        self.ptr
    }

    /// Collect error from C API
    pub fn collect(self, code: i32) -> Result<(), MachineError> {
        if code == 0 {
            Ok(())
        } else {
            Err(MachineError {
                code: unsafe { std::mem::transmute(code as u8) },
                message: self.ptr
            })
        }
    }
}