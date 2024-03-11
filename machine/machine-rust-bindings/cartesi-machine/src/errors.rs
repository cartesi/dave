//! Error handling for the machine emulator

use std::{ffi::c_char, fmt::Display};

use cartesi_machine_sys::*;
use num_traits::FromPrimitive;

use crate::ffi::from_cstr;

/// Error codes returned from machine emulator C API
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, FromPrimitive, ToPrimitive)]
pub enum ErrorCode {
    InvalidArgument = CM_ERROR_CM_ERROR_INVALID_ARGUMENT as isize,
    DomainError = CM_ERROR_CM_ERROR_DOMAIN_ERROR as isize,
    LengthError = CM_ERROR_CM_ERROR_LENGTH_ERROR as isize,
    OutOfRange = CM_ERROR_CM_ERROR_OUT_OF_RANGE as isize,
    LogicError = CM_ERROR_CM_ERROR_LOGIC_ERROR as isize,
    LogicErrorEnd = CM_ERROR_CM_LOGIC_ERROR_END as isize,
    BadOptionalAccess = CM_ERROR_CM_ERROR_BAD_OPTIONAL_ACCESS as isize,
    RuntimeError = CM_ERROR_CM_ERROR_RUNTIME_ERROR as isize,
    RangeError = CM_ERROR_CM_ERROR_RANGE_ERROR as isize,
    OverflowError = CM_ERROR_CM_ERROR_OVERFLOW_ERROR as isize,
    UnderflowError = CM_ERROR_CM_ERROR_UNDERFLOW_ERROR as isize,
    RegexError = CM_ERROR_CM_ERROR_REGEX_ERROR as isize,
    SystemIosBaseFailure = CM_ERROR_CM_ERROR_SYSTEM_IOS_BASE_FAILURE as isize,
    FilesystemError = CM_ERROR_CM_ERROR_FILESYSTEM_ERROR as isize,
    AtomicTxError = CM_ERROR_CM_ERROR_ATOMIC_TX_ERROR as isize,
    NonexistingLocalTime = CM_ERROR_CM_ERROR_NONEXISTING_LOCAL_TIME as isize,
    AmbigousLocalTime = CM_ERROR_CM_ERROR_AMBIGUOUS_LOCAL_TIME as isize,
    FormatError = CM_ERROR_CM_ERROR_FORMAT_ERROR as isize,
    RuntimeErrorEnd = CM_ERROR_CM_RUNTIME_ERROR_END as isize,
    BadTypeid = CM_ERROR_CM_ERROR_BAD_TYPEID as isize,
    BadCast = CM_ERROR_CM_ERROR_BAD_CAST as isize,
    BadAnyCast = CM_ERROR_CM_ERROR_BAD_ANY_CAST as isize,
    BadWeakPtr = CM_ERROR_CM_ERROR_BAD_WEAK_PTR as isize,
    BadFunctionCall = CM_ERROR_CM_ERROR_BAD_FUNCTION_CALL as isize,
    BadAlloc = CM_ERROR_CM_ERROR_BAD_ALLOC as isize,
    BadArrayNewLength = CM_ERROR_CM_ERROR_BAD_ARRAY_NEW_LENGTH as isize,
    BadException = CM_ERROR_CM_ERROR_BAD_EXCEPTION as isize,
    BadVariantAccess = CM_ERROR_CM_ERROR_BAD_VARIANT_ACCESS as isize,
    Exception = CM_ERROR_CM_ERROR_EXCEPTION as isize,
    OtherErrorEnd = CM_ERROR_CM_OTHER_ERROR_END as isize,
    Unknown = CM_ERROR_CM_ERROR_UNKNOWN as isize,
}

/// Error returned from machine emulator C API
#[derive(Debug, Clone)]
pub struct MachineError {
    code: ErrorCode,
    message: Option<String>,
}

impl Display for MachineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Error {:?}: {}",
            self.code as u8,
            self.message.clone().unwrap_or_default()
        )
    }
}

/// Collects an error and cleans the memory. It's used to avoid accidental memory leaks when
/// handling errors using the ownership of [ErrorCollector], the inability to clone it and the
/// [cm_delete_cstring] function.
pub struct ErrorCollector {
    ptr: *mut c_char,
}

impl ErrorCollector {
    /// Creates a new error collector
    pub fn new() -> Self {
        Self {
            ptr: std::ptr::null_mut(),
        }
    }

    /// Gets the pointer to the error message
    pub fn as_mut_ptr(&mut self) -> *mut c_char {
        self.ptr
    }

    /// Collect error from C API
    pub fn collect(self, code: i32) -> Result<(), MachineError> {
        if code == CM_ERROR_CM_ERROR_OK as i32 {
            Ok(())
        } else {
            let message = from_cstr(self.ptr);

            unsafe { cartesi_machine_sys::cm_delete_cstring(self.ptr) };

            Err(MachineError {
                code: FromPrimitive::from_i32(code).expect("cannot transform error code to enum"),
                message,
            })
        }
    }
}
