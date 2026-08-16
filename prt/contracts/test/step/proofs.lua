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
    local proof_bin, next_state_hash = machine:prove_transition(meta_cycle, inputs)
    return agree_hash, next_state_hash, proof_bin
end

-- Test-only mirror of the access-log byte encoding. Layout vectors compare the
-- recomposed bytes with Machine:prove_transition before exposing boundaries.
local function encode_access_logs_for_layout(logs)
    local encoded = {}

    for _, log in ipairs(logs) do
        for _, access in ipairs(log.accesses) do
            if access.log2_size == 3 then
                local read = assert(
                    access.read,
                    "word access must carry its read value"
                )
                table.insert(encoded, read)
            elseif access.type == "read" then
                local read = assert(
                    access.read,
                    "region read must carry its raw value"
                )
                assert(#read == 32, "chain region reads are one bytes32 value")
                table.insert(encoded, read)
                table.insert(encoded, access.read_hash)
            else
                table.insert(encoded, access.read_hash)
            end

            for _, hash in ipairs(access.sibling_hashes) do
                table.insert(encoded, hash)
            end
        end
    end

    return table.concat(encoded)
end

local function encode_da(input_bin)
    return string.pack(">I8", input_bin:len()) .. input_bin
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

local function write_layout_abi(
    meta_cycle,
    agree_hash,
    next_state_hash,
    first_end,
    second_end,
    proof_bin
)
    write_abi({
        meta_cycle:tobe(false),
        agree_hash.digest,
        next_state_hash.digest,
        uint256.fromuinteger(first_end):tobe(false),
        uint256.fromuinteger(second_end):tobe(false),
    }, proof_bin)
end

local args = { ... }
assert(type(assert(args[1])) == "string")

-- This three-instruction RV64 guest clears fromhost and writes x19 to tohost.
-- The emulator interprets that MMIO request and produces the terminal flags.
local terminal_program = string.pack(
    "<I4I4I4",
    0x400082b7, -- lui t0, 0x40008 (HTIF base)
    0x0002b423, -- sd zero, 8(t0) (fromhost)
    0x0132b023  -- sd x19, 0(t0) (tohost)
)
local overflow_program = string.pack("<I4", 0x0000006f) -- jal zero, 0

local function manual_yield_request(reason, payload)
    return (cartesi.HTIF_DEV_YIELD << cartesi.HTIF_DEV_SHIFT)
        | (cartesi.HTIF_YIELD_CMD_MANUAL << cartesi.HTIF_CMD_SHIFT)
        | (reason << cartesi.HTIF_REASON_SHIFT)
        | payload
end

local function new_uarch_cycle_overflow_closing_machine()
    local physical = cartesi.machine({ ram = { length = 4096 } }, {})
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

    return physical, machine, meta_cycle, agree_hash, canonical_post
end

if args[1] == "input-proof-layout" then
    local meta_cycle = uint256.zero()
    local input_bin, input = input_at(0)
    local machine = Machine:new_rollup_advanced_until(
        path,
        meta_cycle,
        { input }
    )
    local agree_hash = machine:state().root_hash
    local revert_root_hash = machine.machine:get_root_hash()

    local cmio_log = machine.machine:log_send_cmio_response(
        cartesi.HTIF_YIELD_REASON_ADVANCE_STATE,
        input_bin,
        revert_root_hash
    )
    local cmio_proof = encode_access_logs_for_layout({ cmio_log })
    local step_log = machine.machine:log_step_uarch()
    local step_proof = encode_access_logs_for_layout({ step_log })
    local next_state_hash = machine:state().root_hash
    local da_proof = encode_da(input_bin)
    local recomposed = da_proof .. cmio_proof .. step_proof

    local canonical_before, canonical_next, canonical_proof = get_proof(
        meta_cycle,
        { input }
    )
    assert(canonical_before == agree_hash)
    assert(canonical_next == next_state_hash)
    assert(canonical_proof == recomposed)

    write_layout_abi(
        meta_cycle,
        agree_hash,
        next_state_hash,
        da_proof:len(),
        da_proof:len() + cmio_proof:len(),
        recomposed
    )
    return
end

if args[1] == "uarch-cycle-overflow-closing-layout" then
    local physical <close>, machine, meta_cycle, agree_hash, canonical_post =
        new_uarch_cycle_overflow_closing_machine()
    local step_log = machine.machine:log_step_uarch()
    local step_proof = encode_access_logs_for_layout({ step_log })
    local reset_log = machine.machine:log_reset_uarch()
    local reset_proof = encode_access_logs_for_layout({ reset_log })
    local next_state_hash = machine:state().root_hash
    local recomposed = step_proof .. reset_proof
    assert(next_state_hash.digest == canonical_post)

    local canonical_physical <close>, canonical_machine, _, canonical_before =
        new_uarch_cycle_overflow_closing_machine()
    local canonical_proof, canonical_next =
        canonical_machine:prove_transition(meta_cycle, {})
    assert(canonical_before == agree_hash)
    assert(canonical_next == next_state_hash)
    assert(canonical_proof == recomposed)

    write_layout_abi(
        meta_cycle,
        agree_hash,
        next_state_hash,
        step_proof:len(),
        recomposed:len(),
        recomposed
    )
    return
end

if args[1] == "out-of-range-nonempty-input-opening" then
    local meta_cycle = uint256.zero()
    local agree_hash, next_state_hash, empty_da_proof =
        get_proof(meta_cycle, {})
    assert(empty_da_proof:sub(1, 8) == string.rep("\0", 8))
    local input_bin = input_at(0)
    local proof_bin = encode_da(input_bin) .. empty_da_proof:sub(9)

    write_abi(
        { meta_cycle:tobe(false), agree_hash.digest, next_state_hash.digest },
        proof_bin
    )
    return
end

local terminal_specs = {
    ["terminal-halt-zero-opening"] = {
        kind = "halt",
        position = "opening",
        payload = 0,
    },
    ["terminal-halt-nonzero-opening"] = {
        kind = "halt",
        position = "opening",
        payload = 7,
    },
    ["terminal-halt-zero-closing"] = {
        kind = "halt",
        position = "closing",
        payload = 0,
    },
    ["terminal-exception-opening"] = {
        kind = "exception",
        position = "opening",
        reason = cartesi.HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION,
        payload = 17,
    },
    ["terminal-exception-closing"] = {
        kind = "exception",
        position = "closing",
        reason = cartesi.HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION,
        payload = 17,
    },
    ["terminal-manual-other-opening"] = {
        kind = "manual-other",
        position = "opening",
        reason = 9,
        payload = 23,
    },
    ["terminal-manual-other-closing"] = {
        kind = "manual-other",
        position = "closing",
        reason = 9,
        payload = 23,
    },
    ["terminal-mcycle-overflow-opening"] = {
        kind = "mcycle-overflow",
        position = "opening",
    },
    ["terminal-mcycle-overflow-closing"] = {
        kind = "mcycle-overflow",
        position = "closing",
    },
}

local function new_terminal_machine(spec)
    local kind = spec.kind
    local registers = { pc = cartesi.AR_RAM_START }
    if kind == "mcycle-overflow" then
        registers.imcyclemax = 3
    end

    local physical = cartesi.machine({
        processor = { registers = registers },
        ram = { length = 4096 },
    }, {})

    if kind == "mcycle-overflow" then
        physical:write_memory(cartesi.AR_RAM_START, overflow_program)
        assert(
            physical:run(arithmetic.max_uint64)
                == cartesi.BREAK_REASON_MCYCLE_OVERFLOW,
            "guest did not reach mcycle overflow"
        )
    else
        local request
        local expected_break
        if kind == "halt" then
            request = (spec.payload << 1) | 1
            expected_break = cartesi.BREAK_REASON_HALTED
        elseif kind == "exception" then
            request = manual_yield_request(spec.reason, spec.payload)
            expected_break = cartesi.BREAK_REASON_YIELDED_MANUALLY
        elseif kind == "manual-other" then
            request = manual_yield_request(spec.reason, spec.payload)
            expected_break = cartesi.BREAK_REASON_YIELDED_MANUALLY
        else
            error("unknown terminal kind " .. tostring(kind))
        end

        physical:write_memory(cartesi.AR_RAM_START, terminal_program)
        physical:write_reg("x19", request)
        assert(
            physical:run(arithmetic.max_uint64) == expected_break,
            "guest did not reach " .. kind
        )
    end

    local machine = setmetatable({ machine = physical }, Machine)
    local state = machine:state()
    assert(state.terminal, kind .. " is not terminal")

    if kind == "halt" then
        assert(
            state.halted
                and not state.manual_yielded
                and not state.mcycle_overflow
        )
        assert(physical:read_reg("htif_tohost_data") >> 1 == spec.payload)
    elseif kind == "exception" then
        assert(
            state.exception and not state.halted and not state.mcycle_overflow
        )
        assert(machine:manual_yield_reason() == spec.reason)
        assert(physical:read_reg("htif_tohost_data") == spec.payload)
    elseif kind == "manual-other" then
        assert(
            state.unexpected_manual_yield
                and not state.halted
                and not state.mcycle_overflow
        )
        assert(machine:manual_yield_reason() == spec.reason)
        assert(physical:read_reg("htif_tohost_data") == spec.payload)
    else
        assert(
            state.mcycle_overflow
                and not state.halted
                and not state.manual_yielded
        )
        assert(physical:read_reg("mcycle") == physical:read_reg("imcyclemax"))
    end

    return physical, machine
end

local terminal_spec = terminal_specs[args[1]]
if terminal_spec then
    local physical <close>, machine = new_terminal_machine(terminal_spec)
    local canonical_terminal_hash = physical:get_root_hash()
    local meta_cycle
    local inputs = {}

    if terminal_spec.position == "opening" then
        meta_cycle = uint256.zero()
        local _, input = input_at(0)
        inputs[1] = input
    else
        meta_cycle = uint256.fromuinteger(cartesi.UARCH_CYCLE_MAX)
        assert(
            physical:run_uarch(cartesi.UARCH_CYCLE_MAX)
                == cartesi.UARCH_BREAK_REASON_UARCH_HALTED,
            "terminal padding did not halt the uarch"
        )
        assert(physical:read_reg("uarch_halt") ~= 0)
    end

    local agree_hash = machine:state().root_hash
    local proof_bin, next_state_hash = machine:prove_transition(meta_cycle, inputs)
    assert(agree_hash ~= next_state_hash)

    if terminal_spec.position == "closing" then
        assert(next_state_hash.digest == canonical_terminal_hash)
        assert(physical:read_reg("uarch_cycle") == 0)
        assert(physical:read_reg("uarch_halt") == 0)
    end

    write_abi(
        { meta_cycle:tobe(false), agree_hash.digest, next_state_hash.digest },
        proof_bin
    )
    return
end

if args[1] == "uarch-cycle-overflow-closing" then
    local physical <close>, machine, meta_cycle, agree_hash, canonical_post =
        new_uarch_cycle_overflow_closing_machine()

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
