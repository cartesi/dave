package.path = "../../prt/client-lua/?.lua;" .. package.path

print = function(...)
    return true
end

local Machine = require "computation.machine"
local uint256 = require "utils.bint" (256)
local consts = require "computation.constants"
local conversion = require "utils.conversion"
local arithmetic = require "utils.arithmetic"

local path = "../../test/programs/yield/machine-image"
local args = { ... }
local mode = assert(args[1])
local inputs = {}
local chunks

for i = 2, #args do
    local arg = assert(args[i])
    if arg == "input" then
        if chunks then
            inputs[#inputs + 1] = "0x" .. table.concat(chunks)
        end
        chunks = {}
    else
        assert(chunks, "input chunk without an input marker")
        chunks[#chunks + 1] = assert(arg:match("^0x(%x*)$"))
    end
end
if chunks then
    inputs[#inputs + 1] = "0x" .. table.concat(chunks)
end

local meta_cycle
local include_counter = false
local revert_next_hash
if mode == "revert" then
    assert(inputs[1])
    local probe = Machine:new_from_path(path)
    probe:feed_input(conversion.bin_from_hex_n(inputs[1]))
    probe:run(arithmetic.max_uint64)
    local bigs = assert(probe._last_input_bigs)
    -- get_logs builds the closing proof but does not expose the checkpoint
    -- root restored by this rejected input. Derive that expected state from
    -- the same emulator until the shared helper owns the complete outcome.
    revert_next_hash = probe:state().root_hash
    meta_cycle = uint256.fromuinteger((bigs << 20) - 1)
    include_counter = true
else
    meta_cycle = uint256.parse(mode)
end

assert((meta_cycle >> (
    consts.log2_uarch_span_to_barch
    + consts.log2_barch_span_to_input
    + consts.log2_input_span_to_epoch
)):iszero())

local epoch_machine = Machine:new_from_path(path)
local epoch_initial_hash = epoch_machine:state().root_hash
local tournament_initial_machine =
    Machine:new_rollup_advanced_until(path, meta_cycle - 1, inputs)
local tournament_initial_hash = tournament_initial_machine:state().root_hash
local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
local agree_hash = machine:state().root_hash
local proofs, next_state_hash =
    Machine.get_logs(path, agree_hash, meta_cycle, inputs)
if revert_next_hash then
    next_state_hash = revert_next_hash
end

local proof_bin = assert(proofs:match([["0x(%x+)"]]), proofs)
proof_bin = (proof_bin:gsub("..", function(cc)
    return string.char(tonumber(cc, 16))
end))
local proof_size_encoded = uint256.fromuinteger(proof_bin:len()):tobe(false)

if proof_bin:len() % 32 ~= 0 then
    proof_bin = proof_bin .. string.rep("\0", 32 - (proof_bin:len() % 32))
end

local words_before_proof = include_counter and 6 or 5
local offset_encoded = uint256.fromuinteger(32 * words_before_proof):tobe(false)
local out_bin = (include_counter and meta_cycle:tobe(false) or "")
    .. epoch_initial_hash.digest
    .. tournament_initial_hash.digest
    .. agree_hash.digest
    .. next_state_hash.digest
    .. offset_encoded
    .. proof_size_encoded
    .. proof_bin

assert(out_bin:len() % 32 == 0)
io.write(conversion.hex_from_bin_n(out_bin))
