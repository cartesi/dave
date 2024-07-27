#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

-- amount of time to fastforward if `IDLE_LIMIT` is reached
local FF_TIME = 30
-- max consecutive iterations of all players idling before the blockchain fastforwards
local IDLE_LIMIT = 5
-- max consecutive iterations of no active players before the program exits
local INACTIVE_LIMIT = 10
-- delay time for blockchain node to be ready
local NODE_DELAY = 2
-- delay between each player
local PLAYER_DELAY = 10

local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"
local Machine = require "computation.machine"

local machine_path = os.getenv("MACHINE_PATH")
local lua_node = helper.str_to_bool(os.getenv("LUA_NODE"))

print "Hello from Dave lua prototype!"

local m = Machine:new_from_path(machine_path)
local initial_hash = m:state().root_hash
local contract = blockchain_constants.root_tournament

-- add more player instances here
local cmds = {
    string.format([[sh -c "echo $$ ; exec ./lua_poc/player/dishonest_player.lua %d %s %s %d | tee dishonest.log"]], 3,
        contract, machine_path, 3),
    -- uncomment below for two extra idle players
    -- string.format([[sh -c "echo $$ ; exec ./lua_poc/player/idle_player.lua %d %s %s | tee idle_1.log"]], 4,
    --     contract, initial_hash),
    -- string.format([[sh -c "echo $$ ; exec ./lua_poc/player/idle_player.lua %d %s %s | tee idle_2.log"]], 5,
    --     contract, initial_hash)
}

if lua_node then
    -- use Lua node to defend
    table.insert(cmds, 1,
        string.format([[sh -c "echo $$ ; exec ./lua_poc/player/honest_player.lua %d %s %s | tee honest.log"]], 2,
            contract,
            machine_path))
else
    -- use Rust node to defend
    table.insert(cmds, 1,
        string.format(
            [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' RUST_LOG='info' ./prt-rs/target/release/cartesi-prt-compute 2>&1 | tee honest.log"]],
            machine_path))
end

local player_start = 2
local node = Blockchain:new()
time.sleep(NODE_DELAY)
table.insert(cmds, 1, [[sh -c "cd contracts && ./deploy_anvil.sh"]])

local pid_reader = {}
local pid_player = {}

for i, cmd in ipairs(cmds) do
    local reader = io.popen(cmd)
    local pid = assert(reader):read()
    if i >= player_start then
        pid_reader[pid] = reader
        pid_player[pid] = i
    end
    time.sleep(PLAYER_DELAY)
end

-- gracefully end children processes
setmetatable(pid_reader, {
    __gc = function(t)
        helper.stop_players(t)
    end
})

local no_active_players = 0
local all_idle = 0
local last_ts = os.time({
    year = 2000,
    month = 1,
    day = 1,
    hour = 0,
    min = 0,
    sec = 0
})
while true do
    local players = 0

    for pid, reader in pairs(pid_reader) do
        local msg_out
        players = players + 1
        last_ts, msg_out = helper.log_to_ts(pid_player[pid], reader, last_ts)

        -- close the reader and delete the reader entry when there's no more msg in the buffer
        -- and the process has already ended
        if msg_out == 0 and helper.is_zombie(pid) then
            helper.log_full(pid_player[pid], string.format("player process %s is dead", pid))
            reader:close()
            pid_reader[pid] = nil
            pid_player[pid] = nil
        end
    end

    if players > 0 then
        if helper.all_players_idle(pid_player) then
            all_idle = all_idle + 1
            helper.rm_all_players_idle(pid_player)
        else
            all_idle = 0
        end

        if all_idle == IDLE_LIMIT then
            print(string.format("all players idle, fastforward blockchain for %d seconds...", FF_TIME))
            blockchain_utils.advance_time(FF_TIME, blockchain_constants.endpoint)
            all_idle = 0
        end
    end

    if players == 0 then
        no_active_players = no_active_players + 1
    else
        no_active_players = 0
    end

    if no_active_players == INACTIVE_LIMIT then
        print("no active players, end program...")
        break
    end
end

print "Good-bye, world!"
