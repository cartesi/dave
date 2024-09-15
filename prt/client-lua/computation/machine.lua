local Hash = require "cryptography.hash"
local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local consts = require "computation.constants"
local helper = require "utils.helper"

local ComputationState = {}
ComputationState.__index = ComputationState

function ComputationState:new(root_hash, halted, uhalted)
    local r = {
        root_hash = root_hash,
        halted = halted,
        uhalted = uhalted
    }
    setmetatable(r, self)
    return r
end

function ComputationState.from_current_machine_state(machine)
    local hash = Hash:from_digest(machine:get_root_hash())
    return ComputationState:new(
        hash,
        machine:read_iflags_H(),
        machine:read_uarch_halt_flag()
    )
end

ComputationState.__tostring = function(x)
    return string.format(
        "{root_hash = %s, halted = %s, uhalted = %s}",
        x.root_hash,
        x.halted,
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
    local start_cycle = machine:read_mcycle()

    -- Machine can never be advanced on the micro arch.
    -- Validators must verify this first
    assert(machine:read_uarch_cycle() == 0)

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
    local low, high = 1, #directories

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local mid_number = directories[mid].number

        if mid_number < cycle and mid_number > current_cycle then
            closest_dir = directories[mid].path
            low = mid + 1  -- Search in the larger half
        else
            high = mid - 1 -- Search in the smaller half
        end
    end

    return closest_dir
end

function Machine:snapshot(cycle)
    local machines_path = "/app/machines"
    if helper.exists(machines_path) then
        local snapshot_path = machines_path .. "/temp_" .. tostring(cycle)
        if not helper.exists(snapshot_path) then
            -- print("saving snapshot", snapshot_path)
            self.machine:store(snapshot_path)
        end
    end
end

function Machine:load_snapshot(cycle)
    local machines_path = "/app/machines"
    local snapshot_path = machines_path .. "/temp_" .. tostring(cycle)

    if not helper.exists(snapshot_path) then
        -- find closest snapshot if direct snapshot doesn't exists
        snapshot_path = find_closest_snapshot(machines_path, self.cycle, cycle)
    end
    if snapshot_path then
        local machine = cartesi.machine(snapshot_path, machine_settings)
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
    local physical_cycle = add_and_clamp(self.start_cycle, cycle) -- TODO reconsider for lambda

    local machine = self.machine
    while not (machine:read_iflags_H() or machine:read_mcycle() == physical_cycle) do
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

function Machine.get_logs(path, cycle, ucycle)
    local machine = Machine:new_from_path(path)
    machine:load_snapshot(cycle)
    local logs
    machine:run(cycle)
    machine:run_uarch(ucycle)

    if ucycle == consts.uarch_span then
        logs = machine.machine:log_uarch_reset { annotations = true, proofs = true }
    else
        logs = machine.machine:log_uarch_step { annotations = true, proofs = true }
    end

    local encoded = {}

    for _, a in ipairs(logs.accesses) do
        if a.log2_size == 3 then
            table.insert(encoded, a.read)
        else
            table.insert(encoded, a.read_hash)
        end

        for _, h in ipairs(a.sibling_hashes) do
            table.insert(encoded, h)
        end
    end

    local data = table.concat(encoded)
    local hex_data = "0x" .. (data:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    return '"' .. hex_data .. '"'
end

return Machine
