local arithmetic = require "utils.arithmetic"

local log2_uarch_span = 20
local log2_emulator_span = 48
local log2_input_span = 24

local constants = {
    log2_uarch_span = log2_uarch_span,
    uarch_span = arithmetic.max_uint(log2_uarch_span),

    log2_emulator_span = log2_emulator_span,
    emulator_span = arithmetic.max_uint(log2_emulator_span),

    log2_input_span = log2_input_span,
    input_span = arithmetic.max_uint(log2_input_span),
}

return constants
