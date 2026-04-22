local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"

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

-- Memory slot where the off-chain client writes the pre-input root hash
-- before sending a CMIO input, so that on-chain `revertIfNeeded` can read it
-- back after a rejected input. Sourced from the emulator directly (v0.20+
-- `cartesi.AR_SHADOW_REVERT_ROOT_HASH_START`, currently 0xfe0); the Solidity
-- side mirrors this through step's auto-generated
-- `EmulatorConstants.REVERT_ROOT_HASH_ADDRESS`.
local CHECKPOINT_ADDRESS = cartesi.AR_SHADOW_REVERT_ROOT_HASH_START
assert(CHECKPOINT_ADDRESS, "emulator missing AR_SHADOW_REVERT_ROOT_HASH_START (expected v0.20+)")

local constants = {
    log2_uarch_span_to_barch = log2_uarch_span_to_barch,
    uarch_span_to_barch = arithmetic.max_uint(log2_uarch_span_to_barch),

    log2_barch_span_to_input = log2_barch_span_to_input,
    barch_span_to_input = arithmetic.max_uint(log2_barch_span_to_input),

    log2_input_span_to_epoch = log2_input_span_to_epoch,
    input_span_to_epoch = arithmetic.max_uint(log2_input_span_to_epoch),

    log2_uarch_span_to_input = log2_uarch_span_to_input,
    log2_uarch_span_to_epoch = log2_uarch_span_to_epoch,

    -- Revert functionality constants
    CHECKPOINT_ADDRESS = CHECKPOINT_ADDRESS
}

return constants
