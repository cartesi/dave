--[[
measure.lua

Benchmark helper for multi‑level PRT. The goal is to discover reasonable
values for the two core commitment parameters at each tournament level:

* log2_stride -> gap between each state hash in commitment;
* height -> number of state hashes inside commitment.

The script proceeds bottom‑up:

1. Leaf level (micro‑architecture)
   *Runs a fully dense commitment*: state hash is computed after every micro‑instruction
   and micro‑architecture reset. We measure how many state hashes we can compute
   within `inner_tournament_timeout` minutes. This fully dense commitment becomes
   the *child* tournament of the next level; as such the next level has its stride fully
   specified.

2. **Parent levels (big‑architecture) –**
   With the child stride and height fixed, we know what must be the stride of the
   parent level. We again measure how many state hashes at this target we can compute
   within `inner_tournament_timeout` minutes, and discover the height. The stop condition
   is when the commitment can be built within the slowdown defined by `root_tournament_slowdown`.
]]

--
-- User configuration
--

-- String containing path where machine was stored.
local machine_path = assert(os.getenv("MACHINE_PATH"))

--- Maximum factor by which the **root** tournament is allowed to slow direct execution
local root_tournament_slowdown = 10.0
assert(root_tournament_slowdown > 1, "root_tournament_slowdown must be greater than 1")

--- Wall‑clock time budget (minutes) to build commitment for *every* inner tournament
local inner_tournament_timeout = 30


--
-- Internal config
--

-- time to run machine in computation hash mode, which will be extrapolated to `inner_tournament_timeout`.
local time_sample_to_extrapolate = 2
assert(time_sample_to_extrapolate <= inner_tournament_timeout)

-- Log2 of the number of micro-instructions to emulate a big instruction.
-- Must match the configured emulator/metastep
local log2_uarch_span_to_barch = 20

-- Log2 of maximum mcycle value
local log2_barch_span_to_input = 48

-- Log2 of maximum inputs per echo
local log2_input_span_to_epoch = 24

-- Big Machine increment roughly 2^26 big instructions per second
local default_log2_big_machine_span = 26
local default_big_machine_span = 1 << default_log2_big_machine_span

-- Machine constructor/load settings
local machine_settings = { htif = { no_console_putchar = true } }

--
-- Timer functions
--

local chronos = require "chronos"
local base_timer = false

local function start_timer()
    assert(not base_timer, "timer already running")
    base_timer = chronos.nanotime()
end

local function check_timer()
    assert(base_timer, "timer not started")
    local total = chronos.nanotime() - base_timer
    return total
end

local function stop_timer()
    local total = check_timer()
    base_timer = false
    return total
end

local cartesi = require "cartesi"
local halted = cartesi.BREAK_REASON_HALTED

-- Helper functions for machine initialization
local function initialize_uarch_machine()
    local m = cartesi.machine(machine_path, machine_settings)
    m:run(1024)
    return m
end

local function initialize_big_machine()
    return cartesi.machine(machine_path, machine_settings)
end


--
--  Micro‑architecture benchmark
--

local function run_big_instruction_in_uarch(machine)
    local uarch_cycle = machine:read_reg("uarch_cycle")
    assert(uarch_cycle == 0)

    local status
    repeat
        uarch_cycle = uarch_cycle + 1
        status = machine:run_uarch(uarch_cycle)
        machine:get_root_hash()
    until status == halted

    machine:reset_uarch()
    machine:get_root_hash()
    return uarch_cycle
end

local function run_uarch_until_timeout()
    local iterations, uinstructions, with_snapshot_time = 0, 0, nil

    -- Run for `time_sample_to_extrapolate` with computation hash to know largest commitment at full density.
    do
        collectgarbage()
        local machine = initialize_uarch_machine()

        start_timer()
        repeat
            uinstructions = uinstructions + run_big_instruction_in_uarch(machine)
            iterations = iterations + 1
        until check_timer() > time_sample_to_extrapolate * 60
        with_snapshot_time = stop_timer()
        assert(machine:read_reg("iflags_H") == 0, "big machine is halted, computation too small")
    end

    -- Extrapolate densest commitment to `inner_tournament_timeout`
    local extrapolated_iterations = iterations * inner_tournament_timeout / time_sample_to_extrapolate
    local log2_iterations = math.floor(math.log(extrapolated_iterations, 2) + 1)


    -- Run same number of instructions achieved by the previous step but without computation hash.
    local no_snapshot_time
    do
        collectgarbage()
        local machine = initialize_uarch_machine()
        start_timer()
        for _ = 1, iterations do
            local status = machine:run_uarch(1 << log2_uarch_span_to_barch)
            assert(status == halted, "error: uarch not halted")
            machine:reset_uarch()
        end
        no_snapshot_time = stop_timer()
    end

    -- Compare running with computation hash and without computation hash (slowdown).
    local slowdown = with_snapshot_time / no_snapshot_time

    return log2_iterations, slowdown, uinstructions // iterations
end


--
-- Big Machine
--

local function run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
    local final_mcycle = machine:read_reg("mcycle") + big_machine_span
    local iterations = 0

    local current_mcycle = machine:read_reg("mcycle")
    while final_mcycle > current_mcycle do
        local i = current_mcycle - machine_base_cycle + 1
        local remaining = snapshot_frequency - (i % snapshot_frequency)
        assert(machine:read_reg("iflags_H") == 0, "big machine is halted, computation too small")

        if current_mcycle + remaining > final_mcycle then
            machine:run(final_mcycle)
            break
        else
            machine:run(current_mcycle + remaining)
            current_mcycle = machine:read_reg("mcycle")
            machine:get_root_hash()
            iterations = iterations + 1
        end
    end

    return iterations
end

-- TODO document
local function run_big_machine_until_timeout(log2_stride)
    -- we pick the smaller value from (snapshot_frequency, default_big_machine_span)
    -- to increment the machine, so we don't overshoot the timeout too much but also run fast
    local snapshot_frequency = 1 << (log2_stride - log2_uarch_span_to_barch)
    local big_machine_span = math.min(snapshot_frequency, default_big_machine_span)

    -- Run for `time_sample_to_extrapolate` with computation hash to know largest commitment
    -- at target density (`log2_stride`).
    local iterations, spans, with_snapshot_time = 0, 0, nil
    do
        collectgarbage()
        local machine = initialize_big_machine()
        local machine_base_cycle = machine:read_reg("mcycle")

        start_timer()
        repeat
            iterations = iterations +
                run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
            spans = spans + 1
        until check_timer() > time_sample_to_extrapolate * 60
        with_snapshot_time = stop_timer()
    end

    -- Extrapolate densest commitment to `inner_tournament_timeout`.
    local extrapolated_iterations = iterations * inner_tournament_timeout / time_sample_to_extrapolate
    local log2_iterations = math.floor(math.log(extrapolated_iterations + 1, 2)) + 1


    -- Run same number of instructions achieved by the previous step but without computation hash.
    local cycles = spans * big_machine_span
    local no_snapshot_time
    do
        collectgarbage()
        local machine = initialize_big_machine()
        start_timer()
        machine:run(machine:read_reg("mcycle") + cycles)
        no_snapshot_time = stop_timer()
    end

    -- Compare running with computation hash and without computation hash (slowdown).
    local slowdown = with_snapshot_time / no_snapshot_time

    return log2_iterations, slowdown
end



--
-- Measure
--

collectgarbage('stop')

print(string.format([[
Starting measurements for %s...

Target root slowdown is set to `%.1fx` slower.
Inner tournament commitment time is set to `%d` minutes.
]], machine_path, root_tournament_slowdown, inner_tournament_timeout))


-- Result variables
local levels = 0
local log2_strides = {} -- log2_gap or log2_step
local heights = {}

local function add_uint64_brackets(src)
    local dst = {}
    for k, v in ipairs(src) do
        dst[k] = "uint64(" .. tostring(v) .. ")"
    end
    return dst -- for convenience (chaining)
end

local function output_results()
    print("level", levels)
    print("log2_stride", "[" .. table.concat(add_uint64_brackets(log2_strides), ", ") .. "]")
    print("height", "[" .. table.concat(add_uint64_brackets(heights), ", ") .. "]")
end

-- 1. Leaf (dense micro)
local log2_iterations, uslowdown, uinstructions = run_uarch_until_timeout()
print(string.format("Average ucycles to run a big instruction: %d", uinstructions))
print(string.format("leaf slowdown: %.1f", uslowdown))

levels = 1
local leaf_height = log2_iterations + log2_uarch_span_to_barch
table.insert(log2_strides, 1, 0)
table.insert(heights, 1, leaf_height)
output_results()
print "uarch done -> CONTINUE\n"

-- 2. Build parent levels until root slowdown <= target
repeat
    levels = levels + 1
    local height, slowdown = run_big_machine_until_timeout(heights[1] + log2_strides[1])
    print(string.format("slowdown of level %d: %.1f", levels, slowdown))

    table.insert(log2_strides, 1, heights[1] + log2_strides[1])

    if slowdown > root_tournament_slowdown then
        table.insert(heights, 1, height)
        output_results()
        print "parent slowdown too high -> CONTINUE\n"
    else
        table.insert(heights, 1,
            log2_input_span_to_epoch + log2_barch_span_to_input + log2_uarch_span_to_barch - log2_strides[1])
        output_results()
        print "root slowdown within target -> FINISHED\n"
        return
    end

    assert(levels < 32, "safety guard: excessive recursion levels (>31)")
until false
