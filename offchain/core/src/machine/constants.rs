use crate::utils::arithmetic;

pub const LOG2_UARCH_SPAN: u64 = 16;
pub const UARCH_SPAN: u64 = arithmetic::max_uint(LOG2_UARCH_SPAN);

pub const LOG2_EMULATOR_SPAN: u64 = 47;
pub const EMULATOR_SPAN: u64 = arithmetic::max_uint(LOG2_EMULATOR_SPAN);
