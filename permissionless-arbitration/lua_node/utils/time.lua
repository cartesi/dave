local clock = os.clock
local time = os.time

local function sleep(number_of_seconds)
    local t0 = clock()
    while clock() - t0 <= number_of_seconds do end
end

local function prettify_clock(status)
    local c = status.clock
    local b = status.last_block
    local s
    if c.last_resume == 0 then
        time_left = c.allowance
        s = string.format("clock paused, %d seconds left", time_left)
    else
        local current = tonumber(b)
        time_left = c.allowance - (current - c.last_resume)
        if time_left >= 0 then
            s = string.format("clock running, %d seconds left", time_left)
        else
            s = string.format("clock running, %d seconds overdue", -time_left)
        end
    end
    return s
end

return {
    sleep = sleep,
    prettify_clock = prettify_clock
}
