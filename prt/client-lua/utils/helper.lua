local color = require "utils.color"

local names = { 'green', 'yellow', 'blue', 'pink', 'cyan', 'white' }
local idle_template = [[ls player%d_idle 2>/dev/null | grep player%d_idle | wc -l]]
local ps_template = [[ps %s | grep defunct | wc -l]]
local helper = {}

local function parse_datetime(datetime_str)
    local patterns = {
        -- Lua node timestamp format
        "(%d%d)/(%d%d)/(%d%d%d%d) (%d%d):(%d%d):(%d%d)", -- MM/DD/YYYY HH:MM:SS
        -- Rust node timestamp format
        "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z" -- YYYY-MM-DDTHH:MM:SSZ
    }

    for _, pattern in ipairs(patterns) do
        local year, month, day, hour, min, sec

        if pattern == patterns[1] then
            month, day, year, hour, min, sec = datetime_str:match(pattern)
        else
            year, month, day, hour, min, sec = datetime_str:match(pattern)
        end

        if year and month and day and hour and min and sec then
            local parsed_time = os.time({
                year = tonumber(year) or 2000,
                month = tonumber(month) or 1,
                day = tonumber(day) or 1,
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            })
            return parsed_time
        end
    end

    return nil, "Invalid date-time format"
end

-- log message with color based on `player_index`
function helper.log_color(player_index, msg)
    local color_index = (player_index - 1) % #names + 1
    print(color.reset .. color.fg[names[color_index]] ..
        string.format("[#%d]%s", player_index, msg) .. color.reset)
end

-- log message with timestamp
function helper.log_timestamp(msg)
    local timestamp = os.date("%m/%d/%Y %X")
    print(string.format("[%s] %s", timestamp, msg))
end

-- log message with color and timestamp based on `player_index`
function helper.log_full(player_index, msg)
    local color_index = (player_index - 1) % #names + 1
    local timestamp = os.date("%m/%d/%Y %X")
    print(color.reset .. color.fg[names[color_index]] ..
        string.format("[#%d][%s] %s", player_index, timestamp, msg) .. color.reset)
end

-- log message with color to `last_ts` based on `player_index`
function helper.log_to_ts(player_index, reader, last_ts)
    -- print everything hold in the buffer which has smaller timestamp
    -- this is to synchronise when there're gaps in between the logs
    local msg_output = 0
    while true do
        local msg = reader:read()
        if msg then
            msg_output = msg_output + 1
            helper.log_color(player_index, msg)

            local timestamp, _ = parse_datetime(msg)
            if timestamp then
                if timestamp > last_ts then
                    last_ts = timestamp
                    break
                end
            end
        else
            break
        end
    end
    return last_ts, msg_output
end

function helper.is_zombie(pid)
    local reader = io.popen(string.format(ps_template, pid))
    if reader then
        local ret = reader:read()
        reader:close()
        return tonumber(ret) == 1
    end
end

function helper.stop_players(pid_reader)
    for pid, reader in pairs(pid_reader) do
        print(string.format("Stopping player with pid %s...", pid))
        os.execute(string.format("kill -15 %s", pid))
        reader:close()
        print "Player stopped"
    end
end

function helper.str_to_bool(str)
    if str == nil then
        return false
    end
    return string.lower(str) == 'true'
end

function helper.touch_player_idle(player_index)
    os.execute(string.format("touch player%d_idle", player_index))
end

function helper.is_player_idle(player_index)
    local reader = io.popen(string.format(idle_template, player_index, player_index))
    if reader then
        local ret = reader:read()
        reader:close()
        return tonumber(ret) == 1
    end
end

function helper.rm_player_idle(player_index)
    os.execute(string.format("rm player%d_idle 2>/dev/null", assert(player_index)))
end

function helper.all_players_idle(pid_player)
    for _, player in pairs(pid_player) do
        if not helper.is_player_idle(player) then
            return false
        end
    end
    return true
end

function helper.rm_all_players_idle(pid_player)
    for _, player in pairs(pid_player) do
        helper.rm_player_idle(player)
    end
    return true
end

--- Check if a file or directory exists in this path
function helper.exists(file)
    local ok, err, code = os.rename(file, file)
    if not ok then
        if code == 13 then
            -- Permission denied, but it exists
            return true
        end
    end
    return ok, err
end

return helper
