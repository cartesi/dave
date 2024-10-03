#!/usr/bin/lua
require "setup_path"

-- amount of time to fastforward if `IDLE_LIMIT` is reached
local FAST_FORWARD_TIME = 300
-- delay time for blockchain node to be ready
local NODE_DELAY = 3
-- number of fake commitment to make
local FAKE_COMMITMENT_COUNT = 1
-- number of idle players
local IDLE_PLAYER_COUNT = 0

-- Required Modules
local new_scoped_require = require "utils.scoped_require"

local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"
local CommitmentBuilder = require "computation.commitment"

local function write_json_file(leafs, root_tournament)
    local prev_accumulated = 0
    local new_leafs = {}
    for i, leaf in ipairs(leafs) do
        new_leafs[i] = {
            hash = leaf.hash,
            repetitions = leaf.accumulated_count - prev_accumulated
        }
        prev_accumulated = leaf.accumulated_count
    end
    local inputs_and_leafs = {
        leafs = new_leafs
    }

    local flat = require "utils.flat"
    local json = require "utils.json"
    local file_path = string.format("/dispute_data/%s/inputs_and_leafs.json", root_tournament)
    local file = io.open(file_path, "w")

    if file then
        file:write(json.encode(flat.flatten(inputs_and_leafs).flat_object))
        file:close()
    end
end

-- Function to setup players
local function setup_players(use_lua_node, extra_data, root_constants, root_tournament, machine_path)
    local player_coroutines = {}
    local player_index = 1
    print("Calculating root commitment...")
    local builder = CommitmentBuilder:new(machine_path)
    local root_commitment = builder:build(0, 0, root_constants.log2_step, root_constants.height)

    if use_lua_node then
        -- use Lua node to defend
        print("Setting up Lua honest player")
        local start_hero = require "runners.hero_runner"
        player_coroutines[player_index] = start_hero(player_index, machine_path, root_commitment, root_tournament,
            extra_data)
    else
        -- use Rust node to defend

        print("Setting up Rust honest player")
        local rust_hero_runner = require "runners.rust_hero_runner"
        -- TODO: switch to use "rust_hero_runner.create_react_once_runner" if we have cache commitments for rust_hero
        player_coroutines[player_index] = rust_hero_runner.create_runner(player_index, machine_path)
        -- write leafs to json file for rust node to use
        write_json_file(root_commitment.leafs, root_tournament)
    end
    player_index = player_index + 1

    if FAKE_COMMITMENT_COUNT > 0 then
        print(string.format("Setting up dishonest player with %d fake commitments", FAKE_COMMITMENT_COUNT))
        local scoped_require = new_scoped_require(_ENV)
        local start_sybil = scoped_require "runners.sybil_runner"
        player_coroutines[player_index] = start_sybil(player_index, machine_path, root_commitment, root_tournament,
            FAKE_COMMITMENT_COUNT)
        player_index = player_index + 1
    end

    if IDLE_PLAYER_COUNT > 0 then
        print(string.format("Setting up %d idle players", IDLE_PLAYER_COUNT))
        local scoped_require = new_scoped_require(_ENV)
        local start_idle = scoped_require "runners.idle_runner"
        for _ = 1, IDLE_PLAYER_COUNT do
            player_coroutines[player_index] = start_idle(player_index, machine_path, root_tournament)
            player_index = player_index + 1
        end
    end

    return player_coroutines
end

local function get_root_constants(root_tournament)
    local Reader = require "player.reader"
    local reader = Reader:new(blockchain_constants.endpoint)
    local root_constants = reader:read_constants(root_tournament)

    return root_constants
end

-- Main Execution
local machine_path = os.getenv("MACHINE_PATH")
local use_lua_node = helper.str_to_bool(os.getenv("LUA_NODE"))
local extra_data = helper.str_to_bool(os.getenv("EXTRA_DATA"))
local root_tournament = blockchain_constants.root_tournament

local blockchain_node = Blockchain:new()
time.sleep(NODE_DELAY)

blockchain_utils.deploy_contracts()
time.sleep(NODE_DELAY)

local root_constants = get_root_constants(root_tournament)
local player_coroutines = setup_players(use_lua_node, extra_data, root_constants, root_tournament, machine_path)
print("Hello from Dave lua prototype!")

while true do
    local idle = true
    local has_live_coroutine = false
    for i, c in ipairs(player_coroutines) do
        if c then
            local success, ret = coroutine.resume(c)
            local status = coroutine.status(c)

            if status == "dead" then
                player_coroutines[i] = false
            end
            if not success then
                print(string.format("coroutine %d fail to resume with error: %s", i, ret))
            elseif ret then
                has_live_coroutine = true
                idle = idle and ret.idle
            end
        end
    end

    if not has_live_coroutine then
        print("No active players, ending program...")
        break
    end

    if idle then
        print(string.format("All players idle, fastforward blockchain for %d seconds...", FAST_FORWARD_TIME))
        blockchain_utils.advance_time(FAST_FORWARD_TIME, blockchain_constants.endpoint)
    end
end

print("Good-bye, world!")
