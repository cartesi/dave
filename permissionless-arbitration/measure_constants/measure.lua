--
-- User configuration
--

-- String containing path where machine was stored.
local machine_directory = "debootstrap-machine-sparsed"

-- How much slower can the root tournament be. Value is an integer
-- representing a fixed-point number with a single decimal
-- (e.g. 10 means 1, 15 means 1.5, and 20 means 2.0)
local root_tournament_slowdown = 25

-- Desiered timeout in inner/nested tournamets.
-- Value is an integer in minutes.
local inner_tournament_timeout = 5


--
-- Internal config
--

-- Log2 of the number of micro-instructions to emulate a big instruction.
-- Must match the configured emulator/metastep
local log2_uarch_span = 16

-- Log2 of maximum mcycle value
local log2_emulator_span = 47

-- Big Machine increment
local big_machine_log2_span = 16

-- Machine constructor/load settings
local machine_settings = { htif = { no_console_putchar = true } }


--
-- Timer functions
--

local chronos = require "chronos"

local base_timer

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
  base_timer = nil
  return total
end

--
-- Machine uarch
--

local cartesi = require "cartesi"
local halted = cartesi.BREAK_REASON_HALTED

local function run_big_instruction_in_uarch(machine)
  local status
  repeat
    status = machine:run_uarch(machine:read_uarch_cycle() + 1)
    machine:get_root_hash()
  until status == halted

  local uinstructions = machine:read_uarch_cycle()
  -- print("UINSTRUCTIONS", uinstructions)
  machine:reset_uarch_state()
  machine:get_root_hash()
  return uinstructions
end

local function run_uarch_until_timeout()
  local iterations, uinstructions, with_snapshot_time = 0, 0, nil
  do
    local machine = cartesi.machine(machine_directory, machine_settings)

    start_timer()
    repeat
      uinstructions = uinstructions + run_big_instruction_in_uarch(machine)
      iterations = iterations + 1
    until check_timer() > inner_tournament_timeout * 60
    with_snapshot_time = stop_timer()
    assert(not machine:read_iflags_H(), "big machine is halted, computation too small")
  end

  local no_snapshot_time
  do
    local machine = cartesi.machine(machine_directory, machine_settings)

    start_timer()
    for _ = 1, iterations do
      local status = machine:run_uarch(1 << log2_uarch_span)
      assert(status == cartesi.BREAK_REASON_HALTED, "error: uarch not halted")
      machine:reset_uarch_state()
    end
    no_snapshot_time = stop_timer()
  end

  local slowdown = math.floor((with_snapshot_time / no_snapshot_time) * 10 + 0.5)
  local log2_iterations = math.floor(math.log(iterations, 2) + 1)

  return log2_iterations, slowdown, uinstructions // iterations
end


--
-- Big Machine
--

local function run_big_machine_span(machine, machine_base_cycle, snapshot_frequency)
  local final_mcycle = machine:read_mcycle() + (1 << big_machine_log2_span)
  local snapshots = 0

  local current_mcycle = machine:read_mcycle()
  while final_mcycle > current_mcycle do
    local i = current_mcycle - machine_base_cycle + 1
    local remaining = snapshot_frequency - (i % snapshot_frequency)

    if current_mcycle + remaining > final_mcycle then
      machine:run(final_mcycle)
      break
    else
      machine:run(current_mcycle + remaining)
      current_mcycle = machine:read_mcycle()
      machine:get_root_hash()
      snapshots = snapshots + 1
    end
  end

  assert(not machine:read_iflags_H(), "big machine is halted, computation too small")
  return snapshots -- this could be calculated with some simple arithmetic instead.
end


local function run_big_machine_until_timeout(previous_log2_stride_count)
  local snapshot_frequency = 1 << (previous_log2_stride_count - log2_uarch_span)

  local snapshots, spans, with_snapshot_time = 0, 0, nil
  do
    local machine = cartesi.machine(machine_directory, machine_settings)
    local machine_base_cycle = machine:read_mcycle()

    start_timer()
    repeat
      snapshots = snapshots + run_big_machine_span(machine, machine_base_cycle, snapshot_frequency)
      spans = spans + 1
    until check_timer() > inner_tournament_timeout * 60
    with_snapshot_time = stop_timer()
  end

  local cycles = spans * (1 << big_machine_log2_span)

  local no_snapshot_time
  do
    local machine = cartesi.machine(machine_directory, machine_settings)
    start_timer()
    machine:run(machine:read_mcycle() + cycles)
    no_snapshot_time = stop_timer()
  end

  local slowdown = math.floor((with_snapshot_time / no_snapshot_time) * 10 + 0.5)
  local log2_snapshots = math.floor(math.log(snapshots + 1, 2)) + 1

  return log2_snapshots, slowdown
end



--
-- Measure
--

assert(root_tournament_slowdown > 10, "root_tournament_slowdown must be greater than 1")

print(string.format([[
Starting measurements...

Target root slowdown is set to `%.1fx` slower.
Inner tournament running time is set to `%d` minutes.
]], root_tournament_slowdown / 10, inner_tournament_timeout))


-- Result variables
local levels = 0
local log2_strides = {} -- log2_gap or log2_step
local heights = {}

local function output_results()
  print("level", levels)
  print("log2_stride", "{" .. table.concat(log2_strides, ", ") .. "}")
  print("height", "{" .. table.concat(heights, ", ") .. "}")
end


-- Measure uarch
local log2_iterations, uslowdown, uinstructions = run_uarch_until_timeout()
print(string.format("Average ucycles to run a big instruction: %d", uinstructions))
print(string.format("leaf slowdown: %.1f", uslowdown / 10))

levels = 1
local leaf_height = log2_iterations + log2_uarch_span
table.insert(log2_strides, 1, 0)
table.insert(heights, 1, leaf_height)
output_results()


-- Measure big emulator
repeat
  local height, slowdown = run_big_machine_until_timeout(heights[1] + log2_strides[1])
  print(string.format("slowdown of level %d: %.1f", levels, slowdown / 10))

  levels = levels + 1

  if slowdown > root_tournament_slowdown then
    table.insert(log2_strides, 1, heights[1] + log2_strides[1])
    table.insert(heights, 1, height)
    output_results()
    print "CONTINUE"
  else
    table.insert(log2_strides, 1, heights[1] + log2_strides[1])
    local acc = 0; for _, i in ipairs(heights) do acc = acc + i end
    table.insert(heights, 1, log2_emulator_span + log2_uarch_span - acc)
    output_results()
    print "FINISHED"
    return
  end
until false
