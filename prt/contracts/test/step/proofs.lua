package.path = "../client-lua/?.lua;" .. package.path

local Machine = require "computation.machine"
local uint256 = require "utils.bint" (256)
local consts = require "computation.constants"
local conversion = require "utils.conversion"

local path = "../../test/programs/yield/machine-image"
local inputs = {}

local args = { ... }
assert(type(assert(args[1])) == "string")
assert(type(assert(args[2])) == "string")
local meta_cycle = uint256.parse(args[1])
local input_size = assert(tonumber(args[2]))
assert((meta_cycle >> (consts.log2_uarch_span_to_barch + consts.log2_barch_span_to_input + consts.log2_input_span_to_epoch))
    :iszero())

for i = 0, input_size - 1 do
    local val = uint256.frominteger(i):tobe(false)
    local input_bin = val

    local x = i
    while x ~= 0 do
        input_bin = input_bin .. input_bin
        x = x >> 1
    end

    local input = conversion.hex_from_bin_n(input_bin)
    table.insert(inputs, input)
end

local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
local agree_hash = machine:state().root_hash

local proofs, next_state_hash = Machine.get_logs(path, agree_hash, meta_cycle, inputs)

local proof_bin = assert(proofs:match([["0x(%x+)"]]), proofs)
proof_bin = (proof_bin:gsub('..', function(cc)
    return string.char(tonumber(cc, 16))
end))
local proof_size = uint256.fromuinteger(proof_bin:len())
local proof_size_encoded = proof_size:tobe(false)

if proof_bin:len() % 32 ~= 0 then
    local zeroes = 32 - (proof_bin:len() % 32)
    proof_bin = proof_bin .. string.rep("\0", zeroes)
end

local dynamic_offset = 32 * 3
local offset_encoded = uint256.fromuinteger(dynamic_offset):tobe(false)

assert(agree_hash.digest:len() == 32)
assert(next_state_hash.digest:len() == 32)
assert(proof_size_encoded:len() == 32)
assert(offset_encoded:len() == 32)
assert(proof_bin:len() % 32 == 0)

local out_bin = agree_hash.digest .. next_state_hash.digest .. offset_encoded .. proof_size_encoded .. proof_bin
assert(out_bin:len() % 32 == 0)
local out = conversion.hex_from_bin_n(out_bin)
io.write(out)
