// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Constants definitions from Cartesi Machine

///
pub mod break_reason {
    use cartesi_machine_sys::*;
    pub const FAILED: u32 = CM_BREAK_REASON_CM_BREAK_REASON_FAILED;
    pub const HALTED: u32 = CM_BREAK_REASON_CM_BREAK_REASON_HALTED;
    pub const YIELDED_MANUALLY: u32 = CM_BREAK_REASON_CM_BREAK_REASON_YIELDED_MANUALLY;
    pub const YIELDED_AUTOMATICALLY: u32 = CM_BREAK_REASON_CM_BREAK_REASON_YIELDED_AUTOMATICALLY;
    pub const YIELDED_SOFTLY: u32 = CM_BREAK_REASON_CM_BREAK_REASON_YIELDED_SOFTLY;
    pub const REACHED_TARGET_MCYCLE: u32 = CM_BREAK_REASON_CM_BREAK_REASON_REACHED_TARGET_MCYCLE;
}

///
pub mod uarch_break_reason {
    use cartesi_machine_sys::*;
    pub const REACHED_TARGET_CYCLE: u32 =
        CM_UARCH_BREAK_REASON_CM_UARCH_BREAK_REASON_REACHED_TARGET_CYCLE;
    pub const UARCH_HALTED: u32 = CM_UARCH_BREAK_REASON_CM_UARCH_BREAK_REASON_UARCH_HALTED;
}

///
pub mod htif {
    use cartesi_machine_sys::*;
    pub const DEVICE_SHIFT: u32 = HTIF_DEV_SHIFT_DEF;
    pub const COMMAND_SHIFT: u32 = HTIF_CMD_SHIFT_DEF;
    pub const DATA_SHIFT: u32 = HTIF_DATA_SHIFT_DEF;
    pub const DEVICE_MASK: u64 = HTIF_DEV_MASK_DEF as u64;
    pub const COMMAND_MASK: u64 = HTIF_CMD_MASK_DEF as u64;
    pub const DATA_MASK: u64 = HTIF_DATA_MASK_DEF as u64;
}

/// HTIF devices
pub mod htif_devices {
    use cartesi_machine_sys::*;
    pub const HALT: u32 = HTIF_DEV_HALT_DEF;
    pub const CONSOLE: u32 = HTIF_DEV_CONSOLE_DEF;
    pub const YIELD: u32 = HTIF_DEV_YIELD_DEF;
}

/// HTIF commands
pub mod htif_commands {
    use cartesi_machine_sys::*;
    pub const HALT_HALT: u32 = HTIF_HALT_CMD_HALT_DEF;
    pub const CONSOLE_GETCHAR: u32 = HTIF_CONSOLE_CMD_GETCHAR_DEF;
    pub const CONSOLE_PUTCHAR: u32 = HTIF_CONSOLE_CMD_PUTCHAR_DEF;
    pub const YIELD_AUTOMATIC: u32 = HTIF_YIELD_CMD_AUTOMATIC_DEF;
    pub const YIELD_MANUAL: u32 = HTIF_YIELD_CMD_MANUAL_DEF;
}

/// HTIF request
pub mod htif_tohost {
    pub mod automatic {
        use cartesi_machine_sys::*;
        pub const PROGRESS: u32 = HTIF_YIELD_AUTOMATIC_REASON_PROGRESS_DEF;
        pub const TX_OUTPUT: u32 = HTIF_YIELD_AUTOMATIC_REASON_TX_OUTPUT_DEF;
        pub const TX_REPORT: u32 = HTIF_YIELD_AUTOMATIC_REASON_TX_REPORT_DEF;
    }

    pub mod manual {
        use cartesi_machine_sys::*;
        pub const RX_ACCEPTED: u32 = HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED_DEF;
        pub const RX_REJECTED: u32 = HTIF_YIELD_MANUAL_REASON_RX_REJECTED_DEF;
        pub const TX_EXCEPTION: u32 = HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION_DEF;
    }
}

/// HTIF reply
pub mod htif_fromhost {
    use cartesi_machine_sys::*;
    pub const ADVANCE_STATE: u32 = HTIF_YIELD_REASON_ADVANCE_STATE_DEF;
    pub const INSPECT_STATE: u32 = HTIF_YIELD_REASON_INSPECT_STATE_DEF;
}

pub mod error {
    use cartesi_machine_sys::*;

    pub const OK: u32 = CM_ERROR_CM_ERROR_OK;

    // Logic errors
    pub const INVALID_ARGUMENT: u32 = CM_ERROR_CM_ERROR_INVALID_ARGUMENT;
    pub const DOMAIN_ERROR: u32 = CM_ERROR_CM_ERROR_DOMAIN_ERROR;
    pub const LENGTH_ERROR: u32 = CM_ERROR_CM_ERROR_LENGTH_ERROR;
    pub const OUT_OF_RANGE: u32 = CM_ERROR_CM_ERROR_OUT_OF_RANGE;
    pub const LOGIC_ERROR: u32 = CM_ERROR_CM_ERROR_LOGIC_ERROR;
    pub const LOGIC_ERROR_END: u32 = CM_ERROR_CM_LOGIC_ERROR_END;

    // Bad optional access error
    pub const BAD_OPTIONAL_ACCESS: u32 = CM_ERROR_CM_ERROR_BAD_OPTIONAL_ACCESS;

    // Runtime errors
    pub const RUNTIME_ERROR: u32 = CM_ERROR_CM_ERROR_RUNTIME_ERROR;
    pub const RANGE_ERROR: u32 = CM_ERROR_CM_ERROR_RANGE_ERROR;
    pub const OVERFLOW_ERROR: u32 = CM_ERROR_CM_ERROR_OVERFLOW_ERROR;
    pub const UNDERFLOW_ERROR: u32 = CM_ERROR_CM_ERROR_UNDERFLOW_ERROR;
    pub const REGEX_ERROR: u32 = CM_ERROR_CM_ERROR_REGEX_ERROR;
    pub const SYSTEM_IOS_BASE_FAILURE: u32 = CM_ERROR_CM_ERROR_SYSTEM_IOS_BASE_FAILURE;
    pub const FILESYSTEM_ERROR: u32 = CM_ERROR_CM_ERROR_FILESYSTEM_ERROR;
    pub const ATOMIC_TX_ERROR: u32 = CM_ERROR_CM_ERROR_ATOMIC_TX_ERROR;
    pub const NONEXISTING_LOCAL_TIME: u32 = CM_ERROR_CM_ERROR_NONEXISTING_LOCAL_TIME;
    pub const AMBIGOUS_LOCAL_TIME: u32 = CM_ERROR_CM_ERROR_AMBIGUOUS_LOCAL_TIME;
    pub const FORMAT_ERROR: u32 = CM_ERROR_CM_ERROR_FORMAT_ERROR;
    pub const RUNTIME_ERROR_END: u32 = CM_ERROR_CM_RUNTIME_ERROR_END;

    // Other errors
    pub const BAD_TYPEID: u32 = CM_ERROR_CM_ERROR_BAD_TYPEID;
    pub const BAD_CAST: u32 = CM_ERROR_CM_ERROR_BAD_CAST;
    pub const BAD_ANY_CAST: u32 = CM_ERROR_CM_ERROR_BAD_ANY_CAST;
    pub const BAD_WEAK_PTR: u32 = CM_ERROR_CM_ERROR_BAD_WEAK_PTR;
    pub const BAD_FUNCTION_CALL: u32 = CM_ERROR_CM_ERROR_BAD_FUNCTION_CALL;
    pub const BAD_ALLOC: u32 = CM_ERROR_CM_ERROR_BAD_ALLOC;
    pub const BAD_ARRAY_NEW_LENGTH: u32 = CM_ERROR_CM_ERROR_BAD_ARRAY_NEW_LENGTH;
    pub const BAD_EXCEPTION: u32 = CM_ERROR_CM_ERROR_BAD_EXCEPTION;
    pub const BAD_VARIANT_ACCESS: u32 = CM_ERROR_CM_ERROR_BAD_VARIANT_ACCESS;
    pub const EXCEPTION: u32 = CM_ERROR_CM_ERROR_EXCEPTION;
    pub const OTHER_ERROR_END: u32 = CM_ERROR_CM_OTHER_ERROR_END;

    // C API Errors
    pub const UNKNOWN: u32 = CM_ERROR_CM_ERROR_UNKNOWN;
}
