-- Measure the emulator-level cost of building PRT commitments.
--
-- The runner starts stress-ng, waits until its worker exists, and stores a
-- manual-yield readiness state. Prepare mode releases it, runs an untimed
-- warmup, and stores the active machine used by every timed phase.

local mode = assert(arg[1], "missing mode (prepare, check, or run)")
local machine_path = assert(arg[2], "missing benchmark machine path")
local workload = assert(arg[3], "missing workload name")
local prepared_path = arg[4]
assert(mode == "prepare" or mode == "check" or mode == "run", "mode must be prepare, check, or run")
if mode == "prepare" then
    assert(prepared_path, "prepare mode needs an output machine path")
else
    assert(not prepared_path, "check and run modes accept no output machine path")
end

local cartesi = require "cartesi"
assert(
    cartesi.VERSION_MAJOR == 0 and cartesi.VERSION_MINOR == 21,
    string.format(
        "Cartesi Machine Lua module 0.21 required, got %d.%d.%d",
        cartesi.VERSION_MAJOR,
        cartesi.VERSION_MINOR,
        cartesi.VERSION_PATCH
    )
)

local function positive_number_from_env(name, default)
    local raw = os.getenv(name)
    local value = raw and tonumber(raw) or default
    assert(value and value > 0, name .. " must be a positive number")
    return value
end

local root_tournament_slowdown = positive_number_from_env("DAVE_ROOT_SLOWDOWN", 10)
assert(root_tournament_slowdown > 1, "DAVE_ROOT_SLOWDOWN must be greater than 1")
local inner_tournament_timeout_minutes =
    positive_number_from_env("DAVE_INNER_TIMEOUT_MINUTES", 30)
local sample_seconds = positive_number_from_env("DAVE_SAMPLE_SECONDS", 120)

local default_log2_big_machine_span = 26
local warmup_mcycles = 1 << 24
local epoch_log2_span = cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
    + cartesi.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
    + cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
local machine_runtime = { console = { output_destination = "to_null" } }
local uarch_halted = cartesi.UARCH_BREAK_REASON_UARCH_HALTED
local reached_target = cartesi.BREAK_REASON_REACHED_TARGET_MCYCLE

local function assert_running(machine, context)
    assert(machine:read_reg("iflags_H") == 0, context .. ": machine halted")
    assert(machine:read_reg("iflags_Y") == 0, context .. ": machine yielded")
    assert(machine:read_reg("uarch_cycle") == 0, context .. ": uarch is not pristine")
end

local function assert_workload_marker(machine)
    assert(machine:read_reg("iflags_H") == 0, "benchmark template is halted")
    assert(machine:read_reg("iflags_Y") == 1, "benchmark template is not at its manual-yield marker")
    assert(machine:read_reg("htif_tohost_dev") == cartesi.HTIF_DEV_YIELD, "marker has wrong HTIF device")
    assert(
        machine:read_reg("htif_tohost_cmd") == cartesi.HTIF_YIELD_CMD_MANUAL,
        "marker is not a manual yield"
    )
    assert(
        machine:read_reg("htif_tohost_reason") == cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        "marker has wrong manual-yield reason"
    )
    assert(machine:read_reg("htif_tohost_data") == 0, "marker carries an unexpected CMIO payload length")
    assert(machine:read_reg("uarch_cycle") == 0, "benchmark template uarch is not pristine")
end

local function release_workload_marker(machine)
    local revert_root = machine:get_root_hash()
    machine:send_cmio_response(cartesi.HTIF_YIELD_REASON_ADVANCE_STATE, workload, revert_root)
    assert_running(machine, "after releasing workload marker")
end

local function load_workload_machine()
    local machine = cartesi.machine(machine_path, machine_runtime)
    assert_running(machine, "loaded active workload fixture")
    return machine
end

local function prepare_fixture()
    local machine <close> = cartesi.machine(machine_path, machine_runtime)
    assert_workload_marker(machine)
    release_workload_marker(machine)
    local start = machine:read_reg("mcycle")
    local target = start + warmup_mcycles
    local break_reason = machine:run(target)
    assert(break_reason == reached_target, "workload stopped during its untimed warmup")
    assert(machine:read_reg("mcycle") == target, "workload warmup stopped at the wrong mcycle")
    assert_running(machine, "after workload warmup")
    machine:store(prepared_path)
    print(string.format("fixture prepared: %s (active at mcycle %d)", workload, target))
end

if mode == "prepare" then
    prepare_fixture()
    return
end

local function check_fixture()
    local machine <close> = load_workload_machine()
    local before = machine:get_root_hash()
    local start = machine:read_reg("mcycle")
    local target = start + (1 << 24)
    local break_reason = machine:run(target)
    assert(break_reason == reached_target, "workload did not reach the positioning probe target")
    assert(machine:read_reg("mcycle") == target, "positioning probe stopped at the wrong mcycle")
    assert_running(machine, "positioning probe")
    assert(machine:get_root_hash() ~= before, "active workload made no state progress")
    print(string.format("fixture ok: %s (warmed mcycle %d)", workload, start))
end

if mode == "check" then
    check_fixture()
    return
end

local chronos = require "chronos"
local base_timer = false

local function start_timer()
    assert(not base_timer, "timer already running")
    base_timer = chronos.nanotime()
end

local function check_timer()
    assert(base_timer, "timer not started")
    return chronos.nanotime() - base_timer
end

local function stop_timer()
    local total = check_timer()
    base_timer = false
    return total
end

local function floor_log2_capacity(value, context)
    assert(value >= 1, context .. ": measured capacity is below one")
    return math.floor(math.log(value, 2))
end

local function run_big_instruction_in_uarch(machine, hash_states)
    assert(machine:read_reg("uarch_cycle") == 0, "uarch did not start pristine")
    local uarch_cycle = 0
    local status
    repeat
        uarch_cycle = uarch_cycle + 1
        status = machine:run_uarch(uarch_cycle)
        if hash_states then
            machine:get_root_hash()
        end
    until status ~= cartesi.UARCH_BREAK_REASON_REACHED_TARGET_UARCH_CYCLE
    assert(status == uarch_halted, "uarch stopped for a reason other than halt")
    machine:reset_uarch()
    if hash_states then
        machine:get_root_hash()
    end
    assert_running(machine, "after one big instruction")
    return uarch_cycle
end

local function run_uarch_until_timeout()
    local iterations = 0
    local uinstructions = 0
    local with_hash_time
    do
        collectgarbage()
        local machine <close> = load_workload_machine()
        start_timer()
        repeat
            uinstructions = uinstructions + run_big_instruction_in_uarch(machine, true)
            iterations = iterations + 1
        until check_timer() >= sample_seconds
        with_hash_time = stop_timer()
    end

    local extrapolated = iterations * inner_tournament_timeout_minutes * 60 / with_hash_time
    local log2_iterations = floor_log2_capacity(extrapolated, "leaf commitment")

    local without_hash_time
    do
        collectgarbage()
        local machine <close> = load_workload_machine()
        start_timer()
        for _ = 1, iterations do
            run_big_instruction_in_uarch(machine, false)
        end
        without_hash_time = stop_timer()
    end

    return log2_iterations, with_hash_time / without_hash_time, uinstructions // iterations
end

local function run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
    local final_mcycle = machine:read_reg("mcycle") + big_machine_span
    local iterations = 0

    while machine:read_reg("mcycle") < final_mcycle do
        local current_mcycle = machine:read_reg("mcycle")
        local relative_cycle = current_mcycle - machine_base_cycle
        local remaining = snapshot_frequency - (relative_cycle % snapshot_frequency)
        local target = math.min(current_mcycle + remaining, final_mcycle)
        assert_running(machine, "before big-machine span")
        local break_reason = machine:run(target)
        assert(break_reason == reached_target, "big machine stopped before its target")
        assert(machine:read_reg("mcycle") == target, "big machine stopped at the wrong mcycle")
        assert_running(machine, "after big-machine span")
        if (target - machine_base_cycle) % snapshot_frequency == 0 then
            machine:get_root_hash()
            iterations = iterations + 1
        end
    end

    return iterations
end

local function run_big_machine_until_timeout(log2_stride)
    local log2_mcycle_stride =
        log2_stride - cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
    assert(
        log2_mcycle_stride >= 0
            and log2_mcycle_stride <= 62
            and log2_stride <= epoch_log2_span,
        "big-machine stride is outside the supported integer geometry"
    )
    local snapshot_frequency = 1 << log2_mcycle_stride
    local big_machine_span = math.min(
        snapshot_frequency,
        1 << math.min(default_log2_big_machine_span, log2_stride)
    )

    local iterations = 0
    local spans = 0
    local with_hash_time
    do
        collectgarbage()
        local machine <close> = load_workload_machine()
        local machine_base_cycle = machine:read_reg("mcycle")
        start_timer()
        repeat
            iterations = iterations
                + run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
            spans = spans + 1
        until check_timer() >= sample_seconds
        with_hash_time = stop_timer()
    end

    local extrapolated = iterations * inner_tournament_timeout_minutes * 60 / with_hash_time
    local log2_iterations = floor_log2_capacity(extrapolated, "big-machine commitment")

    local without_hash_time
    do
        collectgarbage()
        local machine <close> = load_workload_machine()
        local target = machine:read_reg("mcycle") + spans * big_machine_span
        start_timer()
        local break_reason = machine:run(target)
        without_hash_time = stop_timer()
        assert(break_reason == reached_target, "baseline machine stopped before its target")
        assert(machine:read_reg("mcycle") == target, "baseline machine stopped at the wrong mcycle")
        assert_running(machine, "after baseline span")
    end

    return log2_iterations, with_hash_time / without_hash_time
end

collectgarbage("stop")

print(string.format([[
Starting emulator constants benchmark for stress-ng --%s...

Linux boot, process startup, and the fixed warmup are excluded from timing.
Sample duration is %.1f seconds per timed phase.
Target root slowdown is %.1fx.
Inner commitment budget is %.1f minutes.
]], workload, sample_seconds, root_tournament_slowdown, inner_tournament_timeout_minutes))

local levels = 0
local log2_strides = {}
local heights = {}

local function add_uint64_brackets(source)
    local result = {}
    for index, value in ipairs(source) do
        result[index] = "uint64(" .. tostring(value) .. ")"
    end
    return result
end

local function output_results()
    print("workload", workload)
    print("levels", levels)
    print("log2_stride", "[" .. table.concat(add_uint64_brackets(log2_strides), ", ") .. "]")
    print("height", "[" .. table.concat(add_uint64_brackets(heights), ", ") .. "]")
end

local log2_iterations, leaf_slowdown, average_uinstructions = run_uarch_until_timeout()
print(string.format("Average ucycles per big instruction: %d", average_uinstructions))
print(string.format("Leaf slowdown: %.2fx", leaf_slowdown))

levels = 1
local leaf_height = log2_iterations + cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
assert(leaf_height > 0 and leaf_height <= epoch_log2_span, "invalid measured leaf height")
table.insert(log2_strides, 1, 0)
table.insert(heights, 1, leaf_height)
output_results()
print "uarch done -> CONTINUE\n"

repeat
    levels = levels + 1
    local height, slowdown = run_big_machine_until_timeout(heights[1] + log2_strides[1])
    print(string.format("Slowdown of level %d: %.2fx", levels, slowdown))

    table.insert(log2_strides, 1, heights[1] + log2_strides[1])
    if slowdown > root_tournament_slowdown then
        assert(height > 0, "invalid measured inner height")
        table.insert(heights, 1, height)
        output_results()
        print "parent slowdown too high -> CONTINUE\n"
    else
        local root_height = epoch_log2_span - log2_strides[1]
        assert(root_height > 0, "measured geometry leaves no positive root height")
        table.insert(heights, 1, root_height)
        output_results()
        print "root slowdown within target -> FINISHED\n"
        return
    end
    assert(levels < 32, "safety guard: excessive recursion levels")
until false
