use cartesi_dave_arithmetic as arithmetic;

// log2 value of the maximal number of micro instructions that emulates a big instruction
pub const LOG2_UARCH_SPAN_TO_BARCH: u64 = 20;
pub const UARCH_SPAN_TO_BARCH: u64 = arithmetic::max_uint(LOG2_UARCH_SPAN_TO_BARCH);

// log2 value of the maximal number of big instructions that executes an input
pub const LOG2_BARCH_SPAN_TO_INPUT: u64 = 48;
pub const BARCH_SPAN_TO_INPUT: u64 = arithmetic::max_uint(LOG2_BARCH_SPAN_TO_INPUT);

// log2 value of the maximal number of inputs that allowed in an epoch
pub const LOG2_INPUT_SPAN_TO_EPOCH: u64 = 24;
pub const INPUT_SPAN_TO_EPOCH: u64 = arithmetic::max_uint(LOG2_INPUT_SPAN_TO_EPOCH);

// log2 value of the maximal number of micro instructions that executes an input
pub const LOG2_UARCH_SPAN_TO_INPUT: u64 = LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH;
