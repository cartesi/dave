local Hash = require "cryptography.hash"
local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local consts = require "computation.constants"
local conversion = require "utils.conversion"

local ComputationState = {}
ComputationState.__index = ComputationState

function ComputationState:new(root_hash, halted, yielded, uhalted)
    local r = {
        root_hash = root_hash,
        halted = halted,
        yielded = yielded,
        uhalted = uhalted
    }
    setmetatable(r, self)
    return r
end

function ComputationState.from_current_machine_state(machine)
    local hash = Hash:from_digest(machine.machine:get_root_hash())
    return ComputationState:new(
        hash,
        machine:is_halted(),
        machine:is_yielded(),
        machine:is_uarch_halted()
    )
end

ComputationState.__tostring = function(x)
    return string.format(
        "{root_hash = %s, halted = %s, yielded = %s, uhalted = %s}",
        x.root_hash,
        x.halted,
        x.yielded,
        x.uhalted
    )
end


--
---
--

local Machine = {}
Machine.__index = Machine

local machine_settings = { htif = { no_console_putchar = true } }

function Machine:new_from_path(path)
    local machine = cartesi.machine(path, machine_settings)
    local start_cycle = machine:read_reg("mcycle")

    -- Machine can never be advanced on the micro arch.
    -- Validators must verify this first
    assert(machine:read_reg("uarch_cycle") == 0)

    local b = {
        -- path = path,
        machine = machine,
        input_count = 0,
        cycle = 0,
        ucycle = 0,
        start_cycle = start_cycle,
        initial_hash = Hash:from_digest(machine:get_root_hash())
    }

    setmetatable(b, self)
    return b
end

local function add_and_clamp(x, y)
    if math.ult(x, arithmetic.max_uint64 - y) then
        return x + y
    else
        return arithmetic.max_uint64
    end
end

local function advance_rollup(self, meta_cycle, inputs)
    assert(self:is_yielded())
    local input_count = (meta_cycle >> consts.log2_uarch_span_to_input):tointeger()
    local cycle = (meta_cycle >> consts.log2_uarch_span_to_barch):tointeger()
    local ucycle = (meta_cycle & consts.uarch_span_to_barch):tointeger()

    while self.input_count < input_count do
        local input = inputs[self.input_count + 1]

        if not input then
            self.input_count = input_count
            break
        end

        local input_bin = conversion.bin_from_hex_n(input)
        self.machine:send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE, input_bin);

        repeat
            self.machine:run(arithmetic.max_uint64)
        until self:is_halted() or self:is_yielded()
        assert(not self:is_halted())

        self.input_count = self.input_count + 1
    end
    assert(self.input_count == input_count)

    if cycle == 0 and ucycle == 0 then
        return
    end

    local input = inputs[self.input_count + 1]
    if input then
        local input_bin = conversion.bin_from_hex_n(input)
        self.machine:send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE, input_bin);
    end

    self:run(cycle)
    self:run_uarch(ucycle)
end

function Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local input_count = (meta_cycle >> consts.log2_uarch_span_to_input):tointeger()
    assert(arithmetic.ulte(input_count, consts.input_span_to_epoch))

    local machine = Machine:new_from_path(path)
    advance_rollup(machine, meta_cycle, inputs)

    return machine
end

function Machine:state()
    return ComputationState.from_current_machine_state(self)
end

function Machine:is_halted()
    return self.machine:read_reg("iflags_H") ~= 0
end

function Machine:is_yielded()
    return self.machine:read_reg("iflags_Y") ~= 0
end

function Machine:is_uarch_halted()
    return self.machine:read_reg("uarch_halt_flag") ~= 0
end

function Machine:physical_cycle()
    return self.machine:read_reg("mcycle")
end

function Machine:physical_uarch_cycle()
    return self.machine:read_reg("uarch_cycle")
end

function Machine:run_uarch(ucycle)
    assert(arithmetic.ulte(self.ucycle, ucycle), string.format("%u, %u", self.ucycle, ucycle))
    self.machine:run_uarch(ucycle)
    self.ucycle = ucycle
end

function Machine:run(cycle)
    assert(arithmetic.ulte(self.cycle, cycle))

    local machine = self.machine
    local target_physical_cycle = add_and_clamp(self:physical_cycle(), cycle - self.cycle) -- TODO reconsider for lambda

    repeat
        machine:run(target_physical_cycle)
    until self:is_halted() or self:is_yielded() or
        self:physical_cycle() == target_physical_cycle

    self.cycle = cycle

    return self:state()
end

function Machine:increment_uarch()
    self.machine:run_uarch(self.ucycle + 1)
    self.ucycle = self.ucycle + 1

    return self:state()
end

function Machine:ureset()
    self.machine:reset_uarch()
    self.cycle = self.cycle + 1
    self.ucycle = 0

    return self:state()
end

local keccak = require "cartesi".keccak

local function ver(t, p, s)
    local stride = p >> 3
    for k, v in ipairs(s) do
        if (stride >> (k - 1)) % 2 == 0 then
            t = keccak(t, v)
        else
            t = keccak(v, t)
        end
    end

    return t
end

local function encode_access_logs(logs)
    local encoded = {}

    for _, log in ipairs(logs) do
        for _, a in ipairs(log.accesses) do
            if a.log2_size == 3 then
                table.insert(encoded, a.read)
            else
                table.insert(encoded, a.read_hash)
            end

            for _, h in ipairs(a.sibling_hashes) do
                table.insert(encoded, h)
            end
        end
    end

    local data = table.concat(encoded)
    return data
end

local uint256 = require "utils.bint" (256)

local function get_logs_compute(path, agree_hash, meta_cycle)
    error "unimplemented"
    return "", Hash.zero
end

local function encode_da(input_bin)
    local input_size_be = string.pack(">I8", input_bin:len())
    local da_proof = input_size_be .. input_bin
    return da_proof
end

local function get_logs_rollups(path, agree_hash, meta_cycle, inputs)
    local input_mask = (uint256.one() << consts.log2_uarch_span_to_input) - 1
    local big_step_mask = arithmetic.max_uint(consts.log2_uarch_span_to_barch)

    assert(((meta_cycle >> consts.log2_uarch_span_to_input) & (~input_mask)):iszero())
    local input_count = (meta_cycle >> consts.log2_uarch_span_to_input):tointeger()

    local logs = {}

    local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    assert(machine:state().root_hash == agree_hash)

    if (meta_cycle & input_mask):iszero() then
        local input = inputs[input_count + 1]
        local da_proof
        if input then
            local input_bin = conversion.bin_from_hex_n(input)
            local cmio_log = machine.machine:log_send_cmio_response(
                cartesi.CMIO_YIELD_REASON_ADVANCE_STATE,
                input_bin
            )

            table.insert(logs, cmio_log)

            da_proof = encode_da(input_bin)
        else
            da_proof = encode_da("")
        end

        local uarch_step_log = machine.machine:log_step_uarch()
        table.insert(logs, uarch_step_log)

        local step_proof = encode_access_logs(logs)
        local proof = da_proof .. step_proof
        return proof, machine:state().root_hash
    else
        if ((meta_cycle + 1) & big_step_mask):iszero() then
            assert(machine:is_uarch_halted())

            local uarch_step_log = machine.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            local ureset_log = machine.machine:log_reset_uarch()
            table.insert(logs, ureset_log)

            return encode_access_logs(logs), machine:state().root_hash
        else
            local uarch_step_log = machine.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            return encode_access_logs(logs), machine:state().root_hash
        end
    end
end

function Machine.get_logs(path, agree_hash, meta_cycle, inputs)
    local proofs, next_hash
    if inputs then
        proofs, next_hash = get_logs_rollups(path, agree_hash, meta_cycle, inputs)
    else
        proofs, next_hash = get_logs_compute(path, agree_hash, meta_cycle)
    end

    return string.format('"%s"', conversion.hex_from_bin_n(proofs)), next_hash
end

return Machine
