#!/usr/bin/lua
require "setup_path"

-- amount of time to fastforward if `IDLE_LIMIT` is reached
local FAST_FORWARD_TIME = 300
-- max consecutive iterations of all players idling before the blockchain fastforwards
local IDLE_LIMIT = 5
-- delay time for blockchain node to be ready
local NODE_DELAY = 2
-- delay between each player to run its command process
local PLAYER_DELAY = 5
-- number of fake commitment to make
local FAKE_COMMITMENT_COUNT = 1
-- number of idle players
local IDLE_PLAYER_COUNT = 0

-- Required Modules
local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"
local Player = require "player.player"
local hero_hook = require "runners.hero_runner"
local start_sybil = require "runners.sybil_runner"
local start_idle_player = require "runners.idle_runner"

-- Function to setup players
local function setup_players(commands, use_lua_node, extra_data, contract_address, machine_path)
    local player_coroutines = {}
    local player_index = 1

    if use_lua_node then
        -- use Lua node to defend
        local hook
        if extra_data then
            print("Setting up Lua honest player with extra data")
            hook = hero_hook
        else
            print("Setting up Lua honest player")
            hook = false
        end

        local player = Player:new(
            { pk = blockchain_constants.pks[player_index], player_id = player_index },
            contract_address,
            machine_path,
            blockchain_constants.endpoint,
            hook
        )
        player_coroutines[player_index] = coroutine.create(function() player:start() end)
    else
        -- use Rust node to defend
        print("Setting up Rust honest player")
        -- table.insert(commands, string.format(
        --     [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' RUST_LOG='info' \
        --     ../../prt-rs/target/release/cartesi-prt-compute 2>&1 | tee honest.log"]],
        --     machine_path))
    end
    player_index = player_index + 1

    if FAKE_COMMITMENT_COUNT > 0 then
        print(string.format("Setting up dishonest player with %d fake commitments", FAKE_COMMITMENT_COUNT))

        local player = Player:new(
            { pk = blockchain_constants.pks[player_index], player_id = player_index },
            contract_address,
            machine_path,
            blockchain_constants.endpoint,
            false
        )
        player_coroutines[player_index] = coroutine.create(function()
            start_sybil(player, FAKE_COMMITMENT_COUNT)
        end)

        player_index = player_index + 1
    end

    if IDLE_PLAYER_COUNT > 0 then
        print(string.format("Setting up %d idle players", IDLE_PLAYER_COUNT))
        for _ = 1, IDLE_PLAYER_COUNT do
            local player = Player:new(
                { pk = blockchain_constants.pks[player_index], player_id = player_index },
                contract_address,
                machine_path,
                blockchain_constants.endpoint,
                false
            )
            player_coroutines[player_index] = coroutine.create(function()
                start_idle_player(player)
            end)

            player_index = player_index + 1
        end
    end

    return player_coroutines
end

-- Main Execution
local machine_path = os.getenv("MACHINE_PATH")
local use_lua_node = helper.str_to_bool(os.getenv("LUA_NODE"))
local extra_data = helper.str_to_bool(os.getenv("EXTRA_DATA"))
local contract_address = blockchain_constants.root_tournament
local commands = {}

print("Hello from Dave lua prototype!")
local player_coroutines = setup_players(commands, use_lua_node, extra_data, contract_address, machine_path)
local player_count = #player_coroutines

local blockchain_node = Blockchain:new()
time.sleep(NODE_DELAY)

local deploy_cmd = [[sh -c "cd ../../contracts && ./deploy_anvil.sh"]]
local reader = io.popen(deploy_cmd)
local pid = assert(reader):read()
time.sleep(PLAYER_DELAY)

local all_idle_count = 0

while true do
    local idle_count = 0
    for i, c in ipairs(player_coroutines) do
        local success, ret = coroutine.resume(c)
        local status = coroutine.status(c)

        if not success then
            print(string.format("coroutine %d fail to resume with error: %s", i, ret))
        elseif status == "dead" then
            player_coroutines[i] = nil
            player_count = player_count - 1
        elseif ret then
            helper.log_full(i, "player idling")
            idle_count = idle_count + 1
        end
    end

    if idle_count >= player_count then
        all_idle_count = all_idle_count + 1
    end


    if player_count > 0 then
        if all_idle_count == IDLE_LIMIT then
            print(string.format("All players idle, fastforward blockchain for %d seconds...", FAST_FORWARD_TIME))
            blockchain_utils.advance_time(FAST_FORWARD_TIME, blockchain_constants.endpoint)
            all_idle_count = 0
        end
    end

    if player_count == 0 then
        print("No active players, ending program...")
        break
    end
end

print("Good-bye, world!")
