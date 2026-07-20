-- Every polling loop in the harness and the Lua client sleeps through
-- here, so this is the one choke point that can turn a hang into a
-- failure: a dead node otherwise leaves the driving scenario spinning
-- forever (it burned two hours on 2026-07-09). The deadline arms at
-- module load (scenario start) and errors loudly when crossed;
-- SCENARIO_DEADLINE_SECS overrides, 0 disables.
local scenario_start = os.time()
local deadline = tonumber(os.getenv("SCENARIO_DEADLINE_SECS")) or 3600

local function check_deadline()
  if deadline > 0 then
    local elapsed = os.time() - scenario_start
    if elapsed > deadline then
      error(string.format(
        "scenario deadline exceeded: %ds elapsed (limit %ds; set SCENARIO_DEADLINE_SECS to adjust, 0 to disable)",
        elapsed, deadline))
    end
  end
end

local function sleep(seconds)
  check_deadline()
  local ok, how, code = os.execute("exec sleep " .. tonumber(seconds))
  if not ok and how == "signal" and code == 2 then  -- 2 == SIGINT
    os.exit(130, true)
  end
end

local function sleep_ms(ms)
  check_deadline()
  local ok, how, code = os.execute("exec sleep " .. tonumber(ms / 1000) .. "s")
  if not ok and how == "signal" and code == 2 then  -- 2 == SIGINT
    os.exit(130, true)
  end
end

local function sleep_until(condition_f, seconds)
  seconds = seconds or 1

  while not condition_f() do
    sleep(seconds)
  end
end

return {
  sleep = sleep,
  sleep_until = sleep_until,
  sleep_ms = sleep_ms,
}
