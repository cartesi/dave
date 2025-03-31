local arithmetic = require "utils.arithmetic"

local log2_uarch_span_to_barch = 20
local log2_barch_span_to_input = 48
local log2_input_span_to_epoch = 24
local log2_input_span_from_uarch = log2_uarch_span_to_barch + log2_barch_span_to_input

local constants = {
    log2_uarch_span_to_barch = log2_uarch_span_to_barch,
    uarch_span = arithmetic.max_uint(log2_uarch_span_to_barch),

    log2_barch_span_to_input = log2_barch_span_to_input,
    barch_span_to_input = arithmetic.max_uint(log2_barch_span_to_input),

    log2_input_span_to_epoch = log2_input_span_to_epoch,
    input_span_to_epoch = arithmetic.max_uint(log2_input_span_to_epoch),

    log2_input_span_from_uarch = log2_input_span_from_uarch
}

return constants
