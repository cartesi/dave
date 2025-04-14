local color = require "utils.color"

local names = { 'green', 'yellow', 'blue', 'pink', 'cyan', 'white' }
local helper = {}

function helper.parse_datetime(datetime_str)
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
    local prev_msg = false
    while true do
        local msg = reader:read()
        if msg then
            local ts = helper.parse_datetime(msg)
            if ts then
                if ts > last_ts then
                    prev_msg = msg
                    break
                end
            else
                break
            end
            helper.log_color(player_index, msg)
        else
            break
        end
    end
    return prev_msg
end

function helper.is_zombie(pid)
    -- Check if the process is defunct
    local handle = io.popen("ps -p " .. pid .. " -o stat=") -- Get the process status
    if handle then
        local status = handle:read("*l")                    -- Read the status
        handle:close()
        -- Check if the status indicates a defunct process
        if status and status:match("Z") then
            return true -- Process is defunct
        else
            return false
        end
    end
end

function helper.stop_pid(reader, pid)
    print(string.format("Stopping pid %s...", pid))
    os.execute(string.format("kill -15 %s", pid))
    reader:close()
    print "Process stopped"
end

function helper.str_to_bool(str)
    if str == nil then
        return false
    end
    return string.lower(str) == 'true'
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

function helper.remove_file(file)
    local success, err = pcall(os.remove, file)
    if not success then
        -- Ignore the error or handle it if needed
        print("Error removing file:", err) -- Optional: print the error message
    end
end

function helper.is_pid_alive(pid)
    -- Check if the process is alive
    local ok, _, code = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    if ok then
        if helper.is_zombie(pid) then
            return false
        end
        return code == 0 -- Returns true if the process is alive
    end
    return false         -- Returns false if the process is not alive
end

-- Function to create a directory and its parents using os.execute
function helper.mkdir_p(path)
    -- Use os.execute to call the mkdir command with -p option
    local command = "mkdir -p " .. path
    local result = os.execute(command)

    -- Check if the command was successful
    if not result then
        error("Failed to create directory: " .. path)
    end
end

return helper
