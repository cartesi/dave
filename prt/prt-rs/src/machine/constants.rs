use cartesi_dave_arithmetic as arithmetic;

pub const LOG2_UARCH_SPAN: u64 = 20;
pub const UARCH_SPAN: u64 = arithmetic::max_uint(LOG2_UARCH_SPAN);

pub const LOG2_EMULATOR_SPAN: u64 = 48;
pub const EMULATOR_SPAN: u64 = arithmetic::max_uint(LOG2_EMULATOR_SPAN);

pub const LOG2_INPUT_SPAN: u64 = 24;
pub const INPUT_SPAN: u64 = arithmetic::max_uint(LOG2_INPUT_SPAN);
