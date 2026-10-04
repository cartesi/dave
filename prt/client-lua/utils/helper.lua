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

--- Remove a file or a whole directory tree (machine snapshots are
--- directories, which os.remove refuses while they hold files).
function helper.remove_tree(path)
    local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
    if not os.execute("rm -rf -- " .. quoted) then
        print("Error removing: ", path)
    end
end

return helper
