local Hash = require "cryptography.hash"
local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local consts = require "computation.constants"
local helper = require "utils.helper"

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
    local hash = Hash:from_digest(machine:get_root_hash())
    return ComputationState:new(
        hash,
        machine:read_reg("iflags_H"),
        machine:read_reg("iflags_Y"),
        machine:read_reg("uarch_halt_flag")
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
        path = path,
        machine = machine,
        cycle = 0,
        ucycle = 0,
        start_cycle = start_cycle,
        initial_hash = Hash:from_digest(machine:get_root_hash())
    }

    setmetatable(b, self)
    return b
end

function Machine:state()
    return ComputationState.from_current_machine_state(self.machine)
end

local function find_closest_snapshot(path, current_cycle, cycle)
    local directories = {}

    -- Collect all directories and their corresponding numbers
    -- Check if the directory exists and is not empty
    local handle = io.popen('ls -d ' .. path .. '/*/ 2>/dev/null')
    if handle then
        for dir in handle:lines() do
            local dir_name = dir:gsub("/$", "")            -- Get the directory name
            local number = tonumber(dir_name:match("%d+")) -- Extract the number from the name

            if number then
                table.insert(directories, { path = dir_name, number = number })
            end
        end
        handle:close() -- Close the handle
    end

    -- Sort directories by the extracted number
    table.sort(directories, function(a, b) return a.number < b.number end)

    -- Binary search for the closest number smaller than target cycle
    local closest_dir = nil
    local closest_cycle = nil
    local low, high = 1, #directories

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local mid_number = directories[mid].number

        if mid_number < cycle and mid_number > current_cycle then
            closest_dir = directories[mid].path
            closest_cycle = directories[mid].number
            low = mid + 1  -- Search in the larger half
        else
            high = mid - 1 -- Search in the smaller half
        end
    end

    return closest_cycle, closest_dir
end


local function to256BitHex(num) -- Pad the hex string with leading zeros to ensure it's 64 characters long (256 bits)
    return string.format("%064x", num)
end

function Machine:take_snapshot(snapshot_dir, cycle, handle_rollups)
    local input_mask = arithmetic.max_uint(consts.log2_emulator_span)
    if handle_rollups and cycle & input_mask == 0 then
        -- dont snapshot a machine state that's freshly fed with input without advance
        assert(not self.yielded, "don't snapshot a machine state that's freshly fed with input without advance")
    end

    if helper.exists(snapshot_dir) then
        local snapshot_path = snapshot_dir .. "/" .. tostring(cycle)

        if not helper.exists(snapshot_path) then
            -- print("saving snapshot", snapshot_path)
            self.machine:store(snapshot_path)
        end
    end
end

function Machine:load_snapshot(snapshot_dir, cycle)
    local snapshot_cycle = cycle
    local snapshot_path = snapshot_dir .. "/" .. tostring(cycle)

    if not helper.exists(snapshot_path) then
        -- find closest snapshot if direct snapshot doesn't exists
        snapshot_cycle, snapshot_path = find_closest_snapshot(snapshot_dir, self.cycle, cycle)
    end
    if snapshot_path then
        print(string.format("load snapshot from %s", snapshot_path))
        local machine = cartesi.machine(snapshot_path, machine_settings)
        self.cycle = snapshot_cycle
        self.machine = machine
    end
end

local function add_and_clamp(x, y)
    if math.ult(x, arithmetic.max_uint64 - y) then
        return x + y
    else
        return arithmetic.max_uint64
    end
end

function Machine:run(cycle)
    assert(arithmetic.ulte(self.cycle, cycle))

    local machine = self.machine
    local mcycle = machine:read_reg("mcycle")
    local physical_cycle = add_and_clamp(mcycle, cycle - self.cycle) -- TODO reconsider for lambda

    while not (machine:read_reg("iflags_H") or machine:read_reg("iflags_Y") or machine:read_reg("mcycle") == physical_cycle) do
        machine:run(physical_cycle)
    end

    self.cycle = cycle

    return self:state()
end

function Machine:run_uarch(ucycle)
    assert(arithmetic.ulte(self.ucycle, ucycle), string.format("%u, %u", self.ucycle, ucycle))
    self.machine:run_uarch(ucycle)
    self.ucycle = ucycle
end

function Machine:run_with_inputs(cycle, inputs, snapshot_dir)
    local input_mask = arithmetic.max_uint(consts.log2_emulator_span)
    local current_input_index = self.cycle >> consts.log2_emulator_span

    local next_input_index
    local machine_state_without_input = self:state()

    if self.cycle & input_mask == 0 then
        next_input_index = current_input_index
    else
        next_input_index = current_input_index + 1
    end
    local next_input_cycle = next_input_index << consts.log2_emulator_span

    while next_input_cycle <= cycle do
        machine_state_without_input = self:run(next_input_cycle)
        if next_input_cycle == cycle then
            self:take_snapshot(snapshot_dir, next_input_cycle, true)
        end
        local input = inputs[next_input_index + 1]
        if input then
            local h = assert(input:match("0x(%x+)"), input)
            local data_hex = (h:gsub('..', function(cc)
                return string.char(tonumber(cc, 16))
            end))
            self.machine:send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE, data_hex);
        end

        next_input_index = next_input_index + 1
        next_input_cycle = next_input_index << consts.log2_emulator_span
    end

    if cycle > self.cycle then
        machine_state_without_input = self:run(cycle)
        self:take_snapshot(snapshot_dir, cycle, true)
    end

    return machine_state_without_input
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

local function hex_from_bin(bin)
    assert(bin:len() == 32)
    return "0x" .. (bin:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

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

local bint = require 'utils.bint' (256) -- use 256 bits integers

local function encode_access_logs(logs, encode_input)
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
    local hex_data = "0x" .. (data:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    local res
    if encode_input then
        assert(#encode_input >= 2)
        res = "0x" .. to256BitHex((#encode_input - 2) / 2)
        if #encode_input > 2 then
            res = res .. string.sub(encode_input, 3, #encode_input)
        end
        res = res .. string.sub(hex_data, 3, #hex_data)
    else
        res = hex_data
    end
    return '"' .. res .. '"'
end

function Machine.get_logs(path, snapshot_dir, cycle, ucycle, inputs)
    local machine = Machine:new_from_path(path)
    machine:load_snapshot(snapshot_dir, cycle)
    local logs = {}
    local log_type = { annotations = true, proofs = true }
    local encode_input = nil
    if inputs then
        -- treat it as rollups
        -- the cycle may be the cycle to receive input,
        -- we need to include the process of feeding input to the machine in the log
        if cycle == 0 then
            machine:run(cycle)
        else
            machine:run_with_inputs(cycle - 1, inputs, snapshot_dir)
            machine:run(cycle)
        end

        local mask = arithmetic.max_uint(consts.log2_emulator_span);
        -- lua is one based
        local input = inputs[(cycle >> consts.log2_emulator_span) + 1]
        if cycle & mask == 0 then
            if input then
                local h = assert(input:match("0x(%x+)"), input)
                local data_hex = (h:gsub('..', function(cc)
                    return string.char(tonumber(cc, 16))
                end))
                -- need to process input
                if ucycle == 0 then
                    -- need to log cmio
                    table.insert(logs,
                        machine.machine:log_send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE,
                            data_hex,
                            log_type
                        ))
                    table.insert(logs, machine.machine:log_uarch_step(log_type))
                    return encode_access_logs(logs, input)
                else
                    machine.machine:send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE, data_hex)
                end
            else
                if ucycle == 0 then
                    encode_input = "0x"
                end
            end
        end
    else
        -- treat it as compute
        machine:run(cycle)
    end

    machine:run_uarch(ucycle)
    if ucycle == consts.uarch_span then
        table.insert(logs, machine.machine:log_uarch_reset(log_type))
    else
        table.insert(logs, machine.machine:log_uarch_step(log_type))
    end
    return encode_access_logs(logs, encode_input)
end

return Machine
