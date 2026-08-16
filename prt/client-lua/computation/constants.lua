local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"

local log2_window_span = cartesi.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
    + cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
local log2_ruler_span = cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
    + log2_window_span

local constants = {
    uarch_cycle_mask = arithmetic.max_uint(
        cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
    ),
    input_index_mask = arithmetic.max_uint(
        cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
    ),
    log2_window_span = log2_window_span,
    log2_ruler_span = log2_ruler_span,
}

return constants
