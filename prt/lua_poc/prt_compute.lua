#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

-- amount of time to fastforward if `IDLE_LIMIT` is reached
local FAST_FORWARD_TIME = 30
-- max consecutive iterations of all players idling before the blockchain fastforwards
local IDLE_LIMIT = 5
-- max consecutive iterations of no active players before the program exits
local INACTIVE_LIMIT = 10
-- delay time for blockchain node to be ready
local NODE_DELAY = 2
-- delay between each player to run its command process
local PLAYER_DELAY = 10
-- number of fake commitment to make
local FAKE_COMMITMENT_COUNT = 1
-- number of idle players
local IDLE_PLAYER_COUNT = 1

-- Required Modules
local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"

-- Function to setup players
local function setup_players(commands, use_lua_node, contract_address, machine_path)
    table.insert(commands, [[sh -c "cd contracts && ./deploy_anvil.sh"]])
    local player_index = 2

    if use_lua_node then
        -- use Lua node to defend
        print("Setting up Lua honest player")
        table.insert(commands, string.format(
            [[sh -c "echo $$ ; exec ./lua_poc/player/honest_player.lua %d %s %s | tee honest.log"]],
            player_index, contract_address, machine_path))
    else
        -- use Rust node to defend
        print("Setting up Rust honest player")
        table.insert(commands, string.format(
            [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' RUST_LOG='info' \
            ./prt-rs/target/release/cartesi-prt-compute 2>&1 | tee honest.log"]],
            machine_path))
    end
    player_index = player_index + 1

    if FAKE_COMMITMENT_COUNT > 0 then
        print(string.format("Setting up dishonest player with %d fake commitments", FAKE_COMMITMENT_COUNT))
        table.insert(commands, string.format(
            [[sh -c "echo $$ ; exec ./lua_poc/player/dishonest_player.lua %d %s %s %d | tee dishonest.log"]],
            player_index, contract_address, machine_path, FAKE_COMMITMENT_COUNT))
        player_index = player_index + 1
    end

    if IDLE_PLAYER_COUNT > 0 then
        print(string.format("Setting up %d idle players", IDLE_PLAYER_COUNT))
        for _ = 1, IDLE_PLAYER_COUNT do
            table.insert(commands, string.format(
                [[sh -c "echo $$ ; exec ./lua_poc/player/idle_player.lua %d %s %s | tee idle_1.log"]],
                player_index, contract_address, machine_path))
            player_index = player_index + 1
        end
    end
end

-- Main Execution
local machine_path = os.getenv("MACHINE_PATH")
local use_lua_node = helper.str_to_bool(os.getenv("LUA_NODE"))
local contract_address = blockchain_constants.root_tournament
local commands = {}

print("Hello from Dave lua prototype!")
setup_players(commands, use_lua_node, contract_address, machine_path)

local player_start_index = 2
local blockchain_node = Blockchain:new()
time.sleep(NODE_DELAY)

local pid_reader_map = {}
local pid_player_map = {}

for index, command in ipairs(commands) do
    local reader = io.popen(command)
    local pid = assert(reader):read()
    if index >= player_start_index then
        pid_reader_map[pid] = reader
        pid_player_map[pid] = index
    end
    time.sleep(PLAYER_DELAY)
end

-- Gracefully end child processes
setmetatable(pid_reader_map, {
    __gc = function(t)
        helper.stop_players(t)
    end
})

local no_active_players_count = 0
local all_idle_count = 0
local last_timestamp = os.time({ year = 2000, month = 1, day = 1, hour = 0, min = 0, sec = 0 })

while true do
    local active_players = 0

    for pid, reader in pairs(pid_reader_map) do
        local message_out
        active_players = active_players + 1
        last_timestamp, message_out = helper.log_to_ts(pid_player_map[pid], reader, last_timestamp)

        -- close the reader and delete the reader entry when there's no more msg in the buffer
        -- and the process has already ended
        if message_out == 0 and helper.is_zombie(pid) then
            helper.log_full(pid_player_map[pid], string.format("player process %s is dead", pid))
            reader:close()
            pid_reader_map[pid] = nil
            pid_player_map[pid] = nil
        end
    end

    if active_players > 0 then
        if helper.all_players_idle(pid_player_map) then
            all_idle_count = all_idle_count + 1
            helper.rm_all_players_idle(pid_player_map)
        else
            all_idle_count = 0
        end

        if all_idle_count == IDLE_LIMIT then
            print(string.format("All players idle, fastforward blockchain for %d seconds...", FAST_FORWARD_TIME))
            blockchain_utils.advance_time(FAST_FORWARD_TIME, blockchain_constants.endpoint)
            all_idle_count = 0
        end
    end

    if active_players == 0 then
        no_active_players_count = no_active_players_count + 1
    else
        no_active_players_count = 0
    end

    if no_active_players_count == INACTIVE_LIMIT then
        print("No active players, ending program...")
        break
    end
end

print("Good-bye, world!")
