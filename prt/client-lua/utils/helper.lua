local color = require "utils.color"

local names = { 'green', 'yellow', 'blue', 'pink', 'cyan', 'white' }
local helper = {}

-- log message with color and timestamp based on `player_index`
function helper.log_full(player_index, msg)
    local color_index = (player_index - 1) % #names + 1
    local timestamp = os.date("%m/%d/%Y %X")
    print(color.reset .. color.fg[names[color_index]] ..
        string.format("[#%d][%s] %s", player_index, timestamp, msg) .. color.reset)
end

function helper.stop_pid(reader, pid)
    print(string.format("Stopping pid %s...", pid))
    os.execute(string.format("kill -2 %s", pid))
    reader:close()
    print "Process stopped"
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
    print("Removing file: ", file)
    local success, err = os.remove(file)
    if not success then
        -- Ignore the error or handle it if needed
        print("Error removing file: ", file, err) -- Optional: print the error message
    end
end

return helper
