local arithmetic = require "utils.arithmetic"

-- log2 value of the maximal number of micro instructions that emulates a big instruction
local log2_uarch_span_to_barch = 20
-- log2 value of the maximal number of big instructions that executes an input
local log2_barch_span_to_input = 48
-- log2 value of the maximal number of inputs that allowed in an epoch
local log2_input_span_to_epoch = 24
-- log2 value of the maximal number of micro instructions that executes an input
local log2_uarch_span_to_input = log2_uarch_span_to_barch + log2_barch_span_to_input
-- log2 value of the maximal number of meta instructions
local log2_uarch_span_to_epoch = log2_input_span_to_epoch + log2_barch_span_to_input + log2_uarch_span_to_barch

local constants = {
    log2_uarch_span_to_barch = log2_uarch_span_to_barch,
    uarch_span_to_barch = arithmetic.max_uint(log2_uarch_span_to_barch),

    log2_barch_span_to_input = log2_barch_span_to_input,
    barch_span_to_input = arithmetic.max_uint(log2_barch_span_to_input),

    log2_input_span_to_epoch = log2_input_span_to_epoch,
    input_span_to_epoch = arithmetic.max_uint(log2_input_span_to_epoch),

    log2_uarch_span_to_input = log2_uarch_span_to_input,
    log2_uarch_span_to_epoch = log2_uarch_span_to_epoch
}

return constants
