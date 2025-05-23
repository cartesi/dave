require "setup_path"

-- anvil deployment state dump
local ANVIL_PATH = assert(os.getenv("ANVIL_PATH"))

-- machine template hash
local TEMPLATE_MACHINE = assert(os.getenv("TEMPLATE_MACHINE"))

-- addresses
local APP_ADDRESS = assert(os.getenv("APP"))
local CONSENSUS_ADDRESS = assert(os.getenv("CONSENSUS"))
local INPUT_BOX_ADDRESS = assert(os.getenv("INPUT_BOX"))

-- number of epochs to run the rollups test
local MAX_EPOCH = tonumber(os.getenv("MAX_EPOCH")) or math.maxinteger


-- amount of time sleep between each react
local SLEEP_TIME = 2
-- amount of blocks to fastforward if all players are idle
local FAST_FORWARD_TIME = 32
-- delay time for background software to be ready
local NODE_DELAY = 3
-- number of fake commitment to make
local FAKE_COMMITMENT_COUNT = 1
-- number of idle players
local IDLE_PLAYER_COUNT = 0
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
-- local ENCODED_INPUT =
-- "0x0000000000000000000000000000000000000000000000000000000000007a690000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb9226600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000060b61d58000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000001048656c6c6f2076726f6d20446176652100000000000000000000000000000000"

-- Required Modules
local new_scoped_require = require "test_utils.scoped_require"
local helper = require "utils.helper"
local time = require "utils.time"
local Blockchain = require "blockchain.node"
local Dave = require "dave.node"
local Reader = require "dave.reader"
local Sender = require "dave.sender"

-- Main Execution
local _blockchain_node = Blockchain:new(ANVIL_PATH)
local reader = Reader:new()
local sender = Sender:new(INPUT_BOX_ADDRESS, APP_ADDRESS)
time.sleep(NODE_DELAY)

local dave_node = Dave:new(TEMPLATE_MACHINE, APP_ADDRESS, SLEEP_TIME)
time.sleep(NODE_DELAY)


print("Hello from Dave rollups lua prototype!")
print(string.format("rollups test will run for %d epoch(s)", MAX_EPOCH))

-- Function to setup players
local function setup_players(root_tournament, epoch_index)
    local player_coroutines = {}
    local player_index = 1

    local machine_path = dave_node:machine_path(epoch_index)
    print("machine path: {" .. machine_path ..  "}")

    -- TODO: get from blockchain
    local inputs = dave_node:inputs(epoch_index)

    -- TODO: compute locally rather than getting from the node
    print("Calculating root commitment...")
    local root_commitment = dave_node:root_commitment(epoch_index)

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
    local idle_1 = false
    local idle_2 = false
    local idle_3 = false
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

        -- 4 consecutive idle will advance blockchain for faster outcome
        if idle and idle_1 and idle_2 and idle_3 then
            print(string.format("All players idle, fastforward blockchain for %d blocks...", FAST_FORWARD_TIME))
            sender:advance_blocks(FAST_FORWARD_TIME)
        end
        idle_3 = idle_2
        idle_2 = idle_1
        idle_1 = idle

        time.sleep(SLEEP_TIME)
    end
end

while true do
    local sealed_epochs = reader:read_epochs_sealed(CONSENSUS_ADDRESS)

    if #sealed_epochs > MAX_EPOCH then
        print(string.format("rollups test ends with %d epoch(s)", MAX_EPOCH))
        break
    end

    if #sealed_epochs > 0 then
        local epoch = #sealed_epochs - 1
        print("last sealed epoch: " .. epoch)
        local last_sealed_epoch = sealed_epochs[#sealed_epochs]
        sender:tx_add_inputs(INPUT_BOX_ADDRESS, APP_ADDRESS, {ECHO_MSG, ECHO_MSG, ECHO_MSG})

        -- react to last sealed epoch
        local root_tournament = sealed_epochs[#sealed_epochs].tournament
        local work_path = string.format("./_state/%d", epoch)
        if helper.exists(work_path) then
            print(string.format("sybil player attacking epoch %d",
                last_sealed_epoch.epoch_number))
            local player_coroutines = setup_players(root_tournament, epoch)
            run_players(player_coroutines)
        end
    end
    time.sleep(SLEEP_TIME)
end

print("Good-bye, world!")
