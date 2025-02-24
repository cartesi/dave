require "setup_path"

-- consensus contract address in anvil deployment
local CONSENSUS_ADDRESS = os.getenv("CONSENSUS") or "0x0165878A594ca255338adfa4d48449f69242Eb8F"
-- input contract address in anvil deployment
local INPUT_BOX_ADDRESS = os.getenv("INPUT_BOX") or "0x5FbDB2315678afecb367f032d93F642f64180aa3";

-- amount of time sleep between each react
local SLEEP_TIME = 2
-- amount of time to fastforward if `IDLE_LIMIT` is reached
local FAST_FORWARD_TIME = 32
-- amount of time to fastforward to advance an epoch
-- local EPOCH_TIME = 60 * 60 * 24 * 7
-- delay time for blockchain node to be ready
local NODE_DELAY = 3
-- number of fake commitment to make
local FAKE_COMMITMENT_COUNT = 1
-- number of idle players
local IDLE_PLAYER_COUNT = 0
-- app contract address in anvil deployment
local APP_ADDRESS = "0x0000000000000000000000000000000000000000";
-- Hello from Dave!
local ECHO_MSG = "0x48656c6c6f2076726f6d204461766521"
-- Encoded Input blob
-- 31337
-- 0x0000000000000000000000000000000000000000
-- 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
-- 1
-- 0
-- 1
-- 0
-- "0x48656c6c6f2076726f6d204461766521"
-- cast abi-encode "EvmAdvance(uint256,address,address,uint256,uint256,uint256,uint256,bytes)" 31337 "0x0000000000000000000000000000000000000000" "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" 1 1622547800 1 0 "0x48656c6c6f2076726f6d204461766521"
local ENCODED_INPUT =
"0x0000000000000000000000000000000000000000000000000000000000007a690000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb9226600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000060b61d58000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000001048656c6c6f2076726f6d20446176652100000000000000000000000000000000"

-- Required Modules
local new_scoped_require = require "test_utils.scoped_require"

local helper = require "utils.helper"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local blockchain_constants = require "blockchain.constants"
local Blockchain = require "blockchain.node"
local Dave = require "dave.node"
local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local MerkleBuilder = require "cryptography.merkle_builder"
local Reader = require "dave.reader"
local Sender = require "dave.sender"

os.execute("rm -rf _state")

local ROOT_LEAFS_QUERY =
[[sqlite3 ./_state/compute_path/%s/db 'select level,base_cycle,compute_leaf_index,repetitions,HEX(compute_leaf)
from compute_leafs where level=0 ORDER BY compute_leaf_index ASC']]
local function build_root_commitment_from_db(machine_path, root_tournament)
    local builder = MerkleBuilder:new()
    local machine = Machine:new_from_path(machine_path)
    local initial_state = machine:state()

    local handle = io.popen(string.format(ROOT_LEAFS_QUERY, root_tournament))
    assert(handle)
    local rows = handle:read "*a"
    handle:close()

    if rows:find "Error" then
        error(string.format("Read leafs failed:\n%s", rows))
    end

    -- Iterate over each line in the input data
    for line in rows:gmatch("[^\n]+") do
        local _, _, _, repetitions, compute_leaf = line:match(
            "([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
        -- Convert values to appropriate types
        repetitions = tonumber(repetitions)
        compute_leaf = Hash:from_digest_hex("0x" .. compute_leaf)

        builder:add(compute_leaf, repetitions)
    end

    return builder:build(initial_state.root_hash)
end

local INPUTS_QUERY =
[[sqlite3 ./_state/compute_path/%s/db 'select HEX(input)
from inputs ORDER BY input_index ASC']]
local function get_inputs_from_db(root_tournament)
    local handle = io.popen(string.format(INPUTS_QUERY, root_tournament))
    assert(handle)
    local rows = handle:read "*a"
    handle:close()

    if rows:find "Error" then
        error(string.format("Read inputs failed:\n%s", rows))
    end

    local inputs = {}
    -- Iterate over each line in the input data
    for line in rows:gmatch("[^\n]+") do
        local input = line:match("([^|]+)")
        table.insert(inputs, "0x" .. input)
    end

    return inputs
end

-- Function to setup players
local function setup_players(root_tournament, machine_path)
    local player_coroutines = {}
    local player_index = 1
    print("Calculating root commitment...")
    local root_commitment = build_root_commitment_from_db(machine_path, root_tournament)
    local inputs = get_inputs_from_db(root_tournament)

    if FAKE_COMMITMENT_COUNT > 0 then
        print(string.format("Setting up dishonest player with %d fake commitments", FAKE_COMMITMENT_COUNT))
        local scoped_require = new_scoped_require(_ENV)
        local start_sybil = scoped_require "runners.sybil_runner"
        player_coroutines[player_index] = start_sybil(player_index + 1, machine_path, root_commitment, root_tournament,
            FAKE_COMMITMENT_COUNT, inputs)
        player_index = player_index + 1
    end

    if IDLE_PLAYER_COUNT > 0 then
        print(string.format("Setting up %d idle players", IDLE_PLAYER_COUNT))
        local scoped_require = new_scoped_require(_ENV)
        local start_idle = scoped_require "runners.idle_runner"
        for _ = 1, IDLE_PLAYER_COUNT do
            player_coroutines[player_index] = start_idle(player_index + 1, machine_path, root_tournament)
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
            print("No active players, ending attack...")
            break
        end

        if idle then
            print(string.format("All players idle, fastforward blockchain for %d blocks...", FAST_FORWARD_TIME))
            blockchain_utils.advance_time(FAST_FORWARD_TIME, blockchain_constants.endpoint)
        end
        time.sleep(SLEEP_TIME)
    end
end

-- Main Execution
local rpath = assert(io.popen("realpath " .. assert(os.getenv("MACHINE_PATH"))))
local rollups_machine_path = assert(rpath:read())
rpath:close()

local blockchain_node = Blockchain:new(rollups_machine_path .. "/anvil_state.json")
time.sleep(NODE_DELAY)

-- blockchain_utils.deploy_contracts("../../../cartesi-rollups/contracts")
-- time.sleep(NODE_DELAY)

-- trace, debug, info, warn, error
local verbosity = os.getenv("VERBOSITY") or 'debug'
-- 0, 1, full
local trace_level = os.getenv("TRACE_LEVEL") or 'full'
local dave_node = Dave:new(rollups_machine_path .. "/machine-image", CONSENSUS_ADDRESS, INPUT_BOX_ADDRESS, SLEEP_TIME,
    verbosity, trace_level)
time.sleep(NODE_DELAY)

local reader = Reader:new(blockchain_constants.endpoint)
local sender = Sender:new(blockchain_constants.pks[1], blockchain_constants.endpoint)

print("Hello from Dave rollups lua prototype!")

local input_index = 1

while true do
    local sealed_epochs = reader:read_epochs_sealed(CONSENSUS_ADDRESS)

    if #sealed_epochs > 0 then
        local last_sealed_epoch = sealed_epochs[#sealed_epochs]
        for _ = input_index, input_index + 2 do
            sender:tx_add_input(INPUT_BOX_ADDRESS, APP_ADDRESS, ECHO_MSG)
        end

        -- react to last sealed epoch
        local root_tournament = sealed_epochs[#sealed_epochs].tournament
        local work_path = string.format("./_state/compute_path/%s", root_tournament)
        if helper.exists(work_path) then
            print(string.format("sybil player attacking epoch %d",
                last_sealed_epoch.epoch_number))
            local epoch_machine_path = string.format("./_state/snapshots/%d/0", last_sealed_epoch.epoch_number)
            local player_coroutines = setup_players(root_tournament, epoch_machine_path)
            run_players(player_coroutines)
        end
    end
    -- blockchain_utils.advance_time(EPOCH_TIME, blockchain_constants.endpoint)
    time.sleep(SLEEP_TIME)
end

print("Good-bye, world!")
