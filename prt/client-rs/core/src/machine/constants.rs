use cartesi_dave_arithmetic as arithmetic;

pub const LOG2_UARCH_SPAN_TO_BARCH: u64 = 20;
pub const UARCH_SPAN: u64 = arithmetic::max_uint(LOG2_UARCH_SPAN_TO_BARCH);

pub const LOG2_BARCH_SPAN_TO_INPUT: u64 = 48;
pub const BARCH_SPAN_TO_INPUT: u64 = arithmetic::max_uint(LOG2_BARCH_SPAN_TO_INPUT);

pub const LOG2_INPUT_SPAN_TO_EPOCH: u64 = 24;
pub const INPUT_SPAN_TO_EPOCH: u64 = arithmetic::max_uint(LOG2_INPUT_SPAN_TO_EPOCH);

pub const LOG2_INPUT_SPAN_FROM_UARCH: u64 = LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH;
