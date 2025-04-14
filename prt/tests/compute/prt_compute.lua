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
local new_scoped_require = require "test_utils.scoped_require"

local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"
local CommitmentBuilder = require "computation.commitment"

local rpath = assert(io.popen("realpath " .. assert(os.getenv("MACHINE_PATH"))))
local compute_machine_path = assert(rpath:read())
rpath:close()
local lua_node = helper.str_to_bool(os.getenv("LUA_NODE"))
local extra_data = helper.str_to_bool(os.getenv("EXTRA_DATA"))

local function write_json_file(leafs, compute_path)
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
    if not helper.exists(compute_path) then
        helper.mkdir_p(compute_path)
    end
    local file_path = compute_path .. "/inputs_and_leafs.json"
    local file = assert(io.open(file_path, "w"))
    file:write(json.encode(flat.flatten(inputs_and_leafs).flat_object))
    assert(file:close())
end

local function get_root_constants(root_tournament)
    local Reader = require "player.reader"
    local reader = Reader:new(blockchain_constants.endpoint)
    local root_constants = reader:read_constants(root_tournament)

    return root_constants
end

-- Function to setup players
local function setup_players(use_lua_node, use_extra_data, root_tournament, machine_path, compute_path)
    local root_constants = get_root_constants(root_tournament)

    local inputs = nil
    local player_coroutines = {}
    local player_index = 1
    print("Calculating root commitment...")
    local builder = CommitmentBuilder:new(machine_path, nil, nil, compute_path)
    local root_commitment = builder:build(0, 0, root_constants.log2_step, root_constants.height)

    if use_lua_node then
        -- use Lua node to defend
        print("Setting up Lua honest player")
        local start_hero = require "runners.hero_runner"
        player_coroutines[player_index] = start_hero(player_index, machine_path, root_commitment, root_tournament,
            use_extra_data, inputs, compute_path)
    else
        -- use Rust node to defend
        print("Setting up Rust honest player")
        local rust_hero_runner = require "runners.rust_hero_runner"
        player_coroutines[player_index] = rust_hero_runner.create_react_once_runner(player_index, machine_path,
            root_tournament)
        -- write leafs to json file for rust node to use
        write_json_file(root_commitment.leafs, compute_path)
    end
    player_index = player_index + 1

    if FAKE_COMMITMENT_COUNT > 0 then
        print(string.format("Setting up dishonest player with %d fake commitments", FAKE_COMMITMENT_COUNT))
        local scoped_require = new_scoped_require(_ENV)
        local start_sybil = scoped_require "runners.sybil_runner"
        player_coroutines[player_index] = start_sybil(player_index, machine_path, root_commitment, root_tournament,
            FAKE_COMMITMENT_COUNT, inputs, compute_path)
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

-- Function to run players
local function run_players(player_coroutines)
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
            print(string.format("All players idle, fastforward blockchain for %d blocks...", FAST_FORWARD_TIME))
            blockchain_utils.advance_time(FAST_FORWARD_TIME, blockchain_constants.endpoint)
        end
    end
end


local root_tournament = assert(os.getenv("ROOT_TOURNAMENT"))
local compute_path = "./_state/compute_path/" .. string.upper(root_tournament)

-- Main Execution
local blockchain_node = Blockchain:new(compute_machine_path .. "/anvil_state.json")
time.sleep(NODE_DELAY)

local player_coroutines = setup_players(lua_node, extra_data, root_tournament,
    compute_machine_path .. "/machine-image", compute_path)

print("Hello from Dave compute lua prototype!")

run_players(player_coroutines)

print("Good-bye, world!")
