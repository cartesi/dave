local arithmetic = require "utils.arithmetic"

local log2_uarch_span = 16
local log2_emulator_span = 47

local constants = {
    log2_uarch_span = log2_uarch_span,
    uarch_span = arithmetic.max_uint(log2_uarch_span),

    log2_emulator_span = log2_emulator_span,
    emulator_span = arithmetic.max_uint(log2_emulator_span),
}

return constants
