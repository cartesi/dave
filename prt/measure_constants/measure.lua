--
-- User configuration
--

-- String containing path where machine was stored.
local machine_path = os.getenv("MACHINE_PATH")

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

local cartesi = require "cartesi"

-- Helper functions for machine initialization
local function initialize_uarch_machine()
  local m = cartesi.machine(machine_path, machine_settings)
  -- manipulate the initial machine cycle to avoid crash when uarch states being read
  m:run(1024)
  return m
end

local function initialize_big_machine()
  return cartesi.machine(machine_path, machine_settings)
end


--
-- Machine uarch
--

local halted = cartesi.BREAK_REASON_HALTED

local function run_big_instruction_in_uarch(machine)
  local status
  repeat
    status = machine:run_uarch(machine:read_uarch_cycle() + 1)
    machine:get_root_hash()
  until status == halted

  local uinstructions = machine:read_uarch_cycle()
  -- print("UINSTRUCTIONS", uinstructions)
  machine:reset_uarch()
  machine:get_root_hash()
  return uinstructions
end

local function run_uarch_until_timeout()
  local iterations, uinstructions, with_snapshot_time = 0, 0, nil
  do
    local machine = initialize_uarch_machine()

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
    local machine = initialize_uarch_machine()

    start_timer()
    for _ = 1, iterations do
      local status = machine:run_uarch(1 << log2_uarch_span_to_barch)
      assert(status == halted, "error: uarch not halted")
      machine:reset_uarch()
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

local function run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
  local final_mcycle = machine:read_mcycle() + big_machine_span
  local iterations = 0

  local current_mcycle = machine:read_mcycle()
  while final_mcycle > current_mcycle do
    local i = current_mcycle - machine_base_cycle + 1
    local remaining = snapshot_frequency - (i % snapshot_frequency)
    assert(not machine:read_iflags_H(), "big machine is halted, computation too small")

    if current_mcycle + remaining > final_mcycle then
      machine:run(final_mcycle)
      break
    else
      machine:run(current_mcycle + remaining)
      current_mcycle = machine:read_mcycle()
      machine:get_root_hash()
      iterations = iterations + 1
    end
  end

  return iterations
end


local function run_big_machine_until_timeout(log2_stride)
  local snapshot_frequency = 1 << (log2_stride - log2_uarch_span_to_barch)
  -- we pick the smaller value from (snapshot_frequency, default_big_machine_span)
  -- to increment the machine, so we don't overshoot the timeout too much but also run fast
  local big_machine_span = math.min(snapshot_frequency, default_big_machine_span)

  local iterations, spans, with_snapshot_time = 0, 0, nil
  do
    local machine = initialize_big_machine()
    local machine_base_cycle = machine:read_mcycle()

    start_timer()
    repeat
      iterations = iterations +
          run_big_machine_span(machine, machine_base_cycle, snapshot_frequency, big_machine_span)
      spans = spans + 1
    until check_timer() > inner_tournament_timeout * 60
    with_snapshot_time = stop_timer()
  end

  local cycles = spans * big_machine_span

  local no_snapshot_time
  do
    local machine = initialize_big_machine()
    start_timer()
    machine:run(machine:read_mcycle() + cycles)
    no_snapshot_time = stop_timer()
  end

  local slowdown = math.floor((with_snapshot_time / no_snapshot_time) * 10 + 0.5)
  local log2_iterations = math.floor(math.log(iterations + 1, 2)) + 1

  return log2_iterations, slowdown
end



--
-- Measure
--

assert(root_tournament_slowdown > 10, "root_tournament_slowdown must be greater than 1")

print(string.format([[
Starting measurements for %s...

Target root slowdown is set to `%.1fx` slower.
Inner tournament running time is set to `%d` minutes.
]], machine_path, root_tournament_slowdown / 10, inner_tournament_timeout))


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


-- Measure uarch
local log2_iterations, uslowdown, uinstructions = run_uarch_until_timeout()
print(string.format("Average ucycles to run a big instruction: %d", uinstructions))
print(string.format("leaf slowdown: %.1f", uslowdown / 10))

levels = 1
local leaf_height = log2_iterations + log2_uarch_span_to_barch
table.insert(log2_strides, 1, 0)
table.insert(heights, 1, leaf_height)
output_results()
print "CONTINUE\n"

-- Measure big emulator
repeat
  levels = levels + 1
  local height, slowdown = run_big_machine_until_timeout(heights[1] + log2_strides[1])
  print(string.format("slowdown of level %d: %.1f", levels, slowdown / 10))

  table.insert(log2_strides, 1, heights[1] + log2_strides[1])

  if slowdown > root_tournament_slowdown then
    table.insert(heights, 1, height)
    output_results()
    print "CONTINUE\n"
  else
    table.insert(heights, 1,
      log2_input_span_to_epoch + log2_barch_span_to_input + log2_uarch_span_to_barch - log2_strides[1])
    output_results()
    print "FINISHED\n"
    return
  end
until false
