package.path = "../client-lua/?.lua;" .. package.path

print = function(...)
    local args = table.pack(...) -- preserves nils; args.n is the count
    if args.n == 0 then return true end

    local parts = {}
    for i = 1, args.n do
        parts[i] = tostring(args[i])
    end
    local text = table.concat(parts, "\n")

    local f, err = io.open("logs", "a") -- creates file if needed
    if not f then
        return nil, "failed to open logs: " .. tostring(err)
    end

    local ok, werr = f:write(text, "\n") -- on success returns the file handle
    if not ok then
        f:close()
        return nil, "failed to write: " .. tostring(werr)
    end
    f:close()
    return true
end

local Machine = require "computation.machine"
local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local uint256 = require "utils.bint" (256)
local consts = require "computation.constants"
local conversion = require "utils.conversion"

local path = "../../test/programs/yield/machine-image"

local function input_at(i)
    local val = uint256.frominteger(i):tobe(false)
    local input_bin = val

    local x = i
    while x ~= 0 do
        input_bin = input_bin .. input_bin
        x = x >> 1
    end

    return input_bin, conversion.hex_from_bin_n(input_bin)
end

local function get_proof(meta_cycle, inputs)
    local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local agree_hash = machine:state().root_hash
    local proofs, next_state_hash = Machine.get_logs(path, agree_hash, meta_cycle, inputs)
    local proof_bin = assert(proofs:match([["0x(%x+)"]]), proofs)
    proof_bin = (proof_bin:gsub('..', function(cc)
        return string.char(tonumber(cc, 16))
    end))
    return agree_hash, next_state_hash, proof_bin
end

local function write_abi(static_words, proof_bin)
    local proof_size_encoded = uint256.fromuinteger(proof_bin:len()):tobe(false)

    if proof_bin:len() % 32 ~= 0 then
        local zeroes = 32 - (proof_bin:len() % 32)
        proof_bin = proof_bin .. string.rep("\0", zeroes)
    end

    local dynamic_offset = 32 * (#static_words + 1)
    local offset_encoded = uint256.fromuinteger(dynamic_offset):tobe(false)
    local out_bin = table.concat(static_words) .. offset_encoded .. proof_size_encoded .. proof_bin

    for _, word in ipairs(static_words) do
        assert(word:len() == 32)
    end
    assert(proof_size_encoded:len() == 32)
    assert(offset_encoded:len() == 32)
    assert(proof_bin:len() % 32 == 0)
    assert(out_bin:len() % 32 == 0)
    io.write(conversion.hex_from_bin_n(out_bin))
end

local args = { ... }
assert(type(assert(args[1])) == "string")

if args[1] == "uarch-cycle-overflow-closing" then
    local physical <close> = cartesi.machine({ ram = { length = 4096 } }, {})
    physical:write_reg("iflags_Y", 1)
    physical:write_reg("htif_tohost_dev", cartesi.HTIF_DEV_YIELD)
    physical:write_reg("htif_tohost_cmd", cartesi.HTIF_YIELD_CMD_MANUAL)
    physical:write_reg(
        "htif_tohost_reason",
        cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED
    )
    local canonical_post = physical:get_root_hash()
    physical:write_reg("uarch_cycle", cartesi.UARCH_CYCLE_MAX)
    assert(physical:read_reg("uarch_cycle") == cartesi.UARCH_CYCLE_MAX)
    assert(physical:read_reg("uarch_halt") == 0)

    local machine = setmetatable({ machine = physical }, Machine)
    local meta_cycle = uint256.fromuinteger(cartesi.UARCH_CYCLE_MAX)
    local agree_hash = machine:state().root_hash
    assert(agree_hash.digest ~= canonical_post)

    local proof_bin, next_state_hash = machine:prove_transition(meta_cycle, {})
    assert(next_state_hash.digest == canonical_post)
    assert(physical:read_reg("uarch_cycle") == 0)
    assert(physical:read_reg("uarch_halt") == 0)

    write_abi(
        {
            meta_cycle:tobe(false),
            agree_hash.digest,
            next_state_hash.digest,
        },
        proof_bin
    )
    return
end

if args[1] == "first-input-rejection-closing" then
    local input_bin, input = input_at(0)
    local probe = Machine:new_from_path(path)
    local revert_hash = probe:state().root_hash
    local input_start_cycle = probe:physical_cycle()

    probe:feed_input(input_bin)
    repeat
        probe.machine:run(arithmetic.max_uint64)
    until probe:is_halted() or probe:is_manual_yielded() or probe:is_mcycle_overflow()

    assert(probe:state().rejected, "first input did not yield RX_REJECTED")
    local input_bigs = probe:physical_cycle() - input_start_cycle
    assert(input_bigs > 0)
    assert(probe:restore_rejected())
    assert(probe:state().root_hash == revert_hash)

    local meta_cycle =
        (uint256.fromuinteger(input_bigs)
            << cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
        - uint256.one()
    local agree_hash, next_state_hash, proof_bin = get_proof(meta_cycle, { input })
    assert(next_state_hash == revert_hash)

    write_abi(
        { meta_cycle:tobe(false), agree_hash.digest, revert_hash.digest },
        proof_bin
    )
    return
end

assert(type(assert(args[2])) == "string")
local meta_cycle = uint256.parse(assert(args[1]))
local input_size = assert(tonumber(args[2]))
assert((meta_cycle >> consts.log2_ruler_span):iszero())

local inputs = {}
for i = 0, input_size - 1 do
    local _, input = input_at(i)
    table.insert(inputs, input)
end

local agree_hash, next_state_hash, proof_bin = get_proof(meta_cycle, inputs)
write_abi({ agree_hash.digest, next_state_hash.digest }, proof_bin)
