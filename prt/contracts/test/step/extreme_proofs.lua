-- Audit-only companion to proofs.lua: one transition of an epoch whose only
-- input is a 32-byte word (its index, big-endian) at <index>. The generic
-- proofs.lua path builds contiguous inputs 0..n-1, whose sizes double per
-- index bit, so it cannot place an input at the last slot.
--
-- usage: lua test/step/extreme_proofs.lua <counter> <index>
-- prints abi.encode(bytes32 agree, bytes32 next, bytes proof)
package.path = "../client-lua/?.lua;" .. package.path
print = function() return true end -- keep stdout for the ABI word stream

local Machine = require "computation.machine"
local consts = require "computation.constants"
local conversion = require "utils.conversion"
local uint256 = require "utils.bint" (256)

local path = "../../test/programs/yield/machine-image"

local args = { ... }
local meta_cycle = uint256.parse(assert(args[1]))
local index = assert(math.tointeger(tonumber(assert(args[2]))))
assert((meta_cycle >> consts.log2_ruler_span):iszero())
assert(index >= 0 and index <= consts.input_index_mask)

-- advance_rollup skips straight to the target window when inputs[1] is
-- absent, so the agree state is the template's, not the state after
-- index real inputs.
local input_bin = uint256.frominteger(index):tobe(false)
local inputs = { [index + 1] = conversion.hex_from_bin_n(input_bin) }

local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
local agree = machine:state().root_hash
local proof, next_state = machine:prove_transition(meta_cycle, inputs)

local size = uint256.fromuinteger(proof:len()):tobe(false)
if proof:len() % 32 ~= 0 then
    proof = proof .. string.rep("\0", 32 - proof:len() % 32)
end
local offset = uint256.fromuinteger(96):tobe(false)
io.write(conversion.hex_from_bin_n(
    agree.digest .. next_state.digest .. offset .. size .. proof
))
