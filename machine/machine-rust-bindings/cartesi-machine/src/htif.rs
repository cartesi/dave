/// HTIF devices
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, FromPrimitive, ToPrimitive)]
pub enum HtifDevices {
    Halt = cartesi_machine_sys::HTIF_DEVICE_HALT_DEF as isize,
    Console = cartesi_machine_sys::HTIF_DEVICE_CONSOLE_DEF as isize,
    Yield = cartesi_machine_sys::HTIF_DEVICE_YIELD_DEF as isize,
}

pub mod htif_commands {
    pub const HALT_HALT: isize = cartesi_machine_sys::HTIF_HALT_HALT_DEF as isize;
    pub const CONSOLE_GETCHAR: isize = cartesi_machine_sys::HTIF_HALT_HALT_DEF as isize;
    pub const CONSOLE_PUTCHAR: isize = cartesi_machine_sys::HTIF_CONSOLE_PUTCHAR_DEF as isize;
    pub const YIELD_AUTOMATIC: isize = cartesi_machine_sys::HTIF_YIELD_AUTOMATIC_DEF as isize;
    pub const YIELD_MANUAL: isize = cartesi_machine_sys::HTIF_YIELD_MANUAL_DEF as isize;
}

/// HTIF request
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, FromPrimitive, ToPrimitive)]
pub enum HtifRequest {
    Progress = cartesi_machine_sys::HTIF_YIELD_REASON_PROGRESS_DEF as isize,
    RxAccepted = cartesi_machine_sys::HTIF_YIELD_REASON_RX_ACCEPTED_DEF as isize,
    RxRejected = cartesi_machine_sys::HTIF_YIELD_REASON_RX_REJECTED_DEF as isize,
    TxOutput = cartesi_machine_sys::HTIF_YIELD_REASON_TX_OUTPUT_DEF as isize,
    TxReport = cartesi_machine_sys::HTIF_YIELD_REASON_TX_REPORT_DEF as isize,
    TxException = cartesi_machine_sys::HTIF_YIELD_REASON_TX_EXCEPTION_DEF as isize,
}

/// HTIF reply
pub enum HtifReply {
    AdvanceState = cartesi_machine_sys::HTIF_YIELD_REASON_ADVANCE_STATE_DEF as isize,
    InspectState = cartesi_machine_sys::HTIF_YIELD_REASON_INSPECT_STATE_DEF as isize,
}
