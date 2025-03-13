// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Constants definitions from Cartesi Machine

pub mod machine {
    use cartesi_machine_sys::*;
    // pub const CYCLE_MAX: u64 = CM_MCYCLE_MAX as u64;
    pub const HASH_SIZE: u32 = CM_HASH_SIZE;
    pub const TREE_LOG2_WORD_SIZE: u32 = CM_TREE_LOG2_WORD_SIZE;
    pub const TREE_LOG2_PAGE_SIZE: u32 = CM_TREE_LOG2_PAGE_SIZE;
    pub const TREE_LOG2_ROOT_SIZE: u32 = CM_TREE_LOG2_ROOT_SIZE;
}

pub mod pma {
    use cartesi_machine_sys::*;
    pub const RX_START: u64 = CM_PMA_CMIO_RX_BUFFER_START as u64;
    pub const RX_LOG2_SIZE: u64 = CM_PMA_CMIO_RX_BUFFER_LOG2_SIZE as u64;
    pub const TX_START: u64 = CM_PMA_CMIO_TX_BUFFER_START as u64;
    pub const TX_LOG2_SIZE: u64 = CM_PMA_CMIO_TX_BUFFER_LOG2_SIZE as u64;
    pub const RAM_START: u64 = CM_PMA_RAM_START as u64;
}

pub mod break_reason {
    use cartesi_machine_sys::*;
    pub const FAILED: u32 = CM_BREAK_REASON_FAILED;
    pub const HALTED: u32 = CM_BREAK_REASON_HALTED;
    pub const YIELDED_MANUALLY: u32 = CM_BREAK_REASON_YIELDED_MANUALLY;
    pub const YIELDED_AUTOMATICALLY: u32 = CM_BREAK_REASON_YIELDED_AUTOMATICALLY;
    pub const YIELDED_SOFTLY: u32 = CM_BREAK_REASON_YIELDED_SOFTLY;
    pub const REACHED_TARGET_MCYCLE: u32 = CM_BREAK_REASON_REACHED_TARGET_MCYCLE;
}

pub mod uarch_break_reason {
    use cartesi_machine_sys::*;
    pub const REACHED_TARGET_CYCLE: u32 = CM_UARCH_BREAK_REASON_REACHED_TARGET_CYCLE;
    pub const UARCH_HALTED: u32 = CM_UARCH_BREAK_REASON_UARCH_HALTED;
}

pub mod access_log_type {
    use cartesi_machine_sys::*;
    pub const ANNOTATIONS: u32 = CM_ACCESS_LOG_TYPE_ANNOTATIONS;
    pub const LARGE_DATA: u32 = CM_ACCESS_LOG_TYPE_LARGE_DATA;
}

pub mod cmio {
    /// CMIO commands
    pub mod commands {
        use cartesi_machine_sys::*;
        pub const YIELD_AUTOMATIC: u8 = CM_CMIO_YIELD_COMMAND_AUTOMATIC as u8;
        pub const YIELD_MANUAL: u8 = CM_CMIO_YIELD_COMMAND_MANUAL as u8;
    }

    /// CMIO request
    pub mod tohost {
        pub mod automatic {
            use cartesi_machine_sys::*;
            pub const PROGRESS: u16 = CM_CMIO_YIELD_AUTOMATIC_REASON_PROGRESS as u16;
            pub const TX_OUTPUT: u16 = CM_CMIO_YIELD_AUTOMATIC_REASON_TX_OUTPUT as u16;
            pub const TX_REPORT: u16 = CM_CMIO_YIELD_AUTOMATIC_REASON_TX_REPORT as u16;
        }

        pub mod manual {
            use cartesi_machine_sys::*;
            pub const RX_ACCEPTED: u16 = CM_CMIO_YIELD_MANUAL_REASON_RX_ACCEPTED as u16;
            pub const RX_REJECTED: u16 = CM_CMIO_YIELD_MANUAL_REASON_RX_REJECTED as u16;
            pub const TX_EXCEPTION: u16 = CM_CMIO_YIELD_MANUAL_REASON_TX_EXCEPTION as u16;
        }
    }

    /// CMIO response
    pub mod fromhost {
        use cartesi_machine_sys::*;
        pub const ADVANCE_STATE: u16 = CM_CMIO_YIELD_REASON_ADVANCE_STATE as u16;
        pub const INSPECT_STATE: u16 = CM_CMIO_YIELD_REASON_INSPECT_STATE as u16;
    }
}

pub mod error_code {
    use cartesi_machine_sys::*;

    pub const OK: i32 = CM_ERROR_OK;

    // Logic errors
    pub const INVALID_ARGUMENT: i32 = CM_ERROR_INVALID_ARGUMENT;
    pub const DOMAIN_ERROR: i32 = CM_ERROR_DOMAIN_ERROR;
    pub const LENGTH_ERROR: i32 = CM_ERROR_LENGTH_ERROR;
    pub const OUT_OF_RANGE: i32 = CM_ERROR_OUT_OF_RANGE;
    pub const LOGIC_ERROR: i32 = CM_ERROR_LOGIC_ERROR;

    // Runtime errors
    pub const RUNTIME_ERROR: i32 = CM_ERROR_RUNTIME_ERROR;
    pub const RANGE_ERROR: i32 = CM_ERROR_RANGE_ERROR;
    pub const OVERFLOW_ERROR: i32 = CM_ERROR_OVERFLOW_ERROR;
    pub const UNDERFLOW_ERROR: i32 = CM_ERROR_UNDERFLOW_ERROR;
    pub const REGEX_ERROR: i32 = CM_ERROR_REGEX_ERROR;
    pub const SYSTEM_ERROR: i32 = CM_ERROR_SYSTEM_ERROR;

    // Other errors
    pub const BAD_TYPEID: i32 = CM_ERROR_BAD_TYPEID;
    pub const BAD_CAST: i32 = CM_ERROR_BAD_CAST;
    pub const BAD_ANY_CAST: i32 = CM_ERROR_BAD_ANY_CAST;
    pub const BAD_OPTIONAL_ACCESS: i32 = CM_ERROR_BAD_OPTIONAL_ACCESS;
    pub const BAD_WEAK_PTR: i32 = CM_ERROR_BAD_WEAK_PTR;
    pub const BAD_FUNCTION_CALL: i32 = CM_ERROR_BAD_FUNCTION_CALL;
    pub const BAD_ALLOC: i32 = CM_ERROR_BAD_ALLOC;
    pub const BAD_ARRAY_NEW_LENGTH: i32 = CM_ERROR_BAD_ARRAY_NEW_LENGTH;
    pub const BAD_EXCEPTION: i32 = CM_ERROR_BAD_EXCEPTION;
    pub const BAD_VARIANT_ACCESS: i32 = CM_ERROR_BAD_VARIANT_ACCESS;
    pub const EXCEPTION: i32 = CM_ERROR_EXCEPTION;

    // C API Errors
    pub const UNKNOWN: i32 = CM_ERROR_UNKNOWN;
}
