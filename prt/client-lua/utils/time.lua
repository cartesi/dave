local function sleep(seconds)
  local ok, how, code = os.execute("exec sleep " .. tonumber(seconds))
  if not ok and how == "signal" and code == 2 then  -- 2 == SIGINT
    os.exit(130, true)
  end
end

local function sleep_ms(ms)
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
