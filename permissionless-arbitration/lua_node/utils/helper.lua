local color = require "utils.color"

local names = {'green', 'yellow', 'blue', 'pink', 'cyan', 'white'}
local idle_template = [[ls player%d_idle 2>/dev/null | grep player%d_idle | wc -l]]
local ps_template = [[ps %s | grep defunct | wc -l]]
local helper = {}

function helper.log(player_index, msg)
    local color_index = (player_index - 1) % #names + 1
    local timestamp = os.date("%m/%d/%Y %X")
    print(color.reset .. color.fg[names[color_index]] ..
        string.format("[#%d][%s] %s", player_index, timestamp, msg) .. color.reset)
end

function helper.log_to_ts(reader, last_ts)
    -- print everything hold in the buffer which has smaller timestamp
    -- this is to synchronise when there're gaps in between the logs
    local msg_output = 0
    while true do
        local msg = reader:read()
        if msg then
            msg_output = msg_output + 1
            print(msg)

            local i, j = msg:find("%d%d/%d%d/%d%d%d%d %d%d:%d%d:%d%d")
            if i and j then
                local timestamp = msg:sub(i, j)
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
    local ret = reader:read()
    reader:close()
    return tonumber(ret) == 1
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
    local ret = reader:read()
    reader:close()
    return tonumber(ret) == 1
end

function helper.rm_player_idle(player_index)
    os.execute(string.format("rm player%d_idle 2>/dev/null", player_index))
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

return helper
