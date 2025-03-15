local helper = require "utils.helper"

local default_account_number = 40

-- spawn an anvil node with 40 accounts, auto-mine, and finalize block at height N-2
local function start_blockchain(load_state)
    print(string.format("Starting blockchain with %d accounts...", default_account_number))

    local cmd
    if load_state then
        cmd = string.format(
            [[sh -c "echo $$ ; exec anvil --load-state %s --preserve-historical-states --block-time 1 --slots-in-an-epoch 1 -a %d > anvil.log 2>&1"]],
            load_state,
            default_account_number
        )
    else
        cmd = string.format(
            [[sh -c "echo $$ ; exec anvil --preserve-historical-states --block-time 1 --slots-in-an-epoch 1 -a %d > anvil.log 2>&1"]],
            default_account_number
        )
    end

    local reader = io.popen(cmd)
    assert(reader, "`popen` returned nil reader")

    local pid = tonumber(reader:read())

    local handle = { reader = reader, pid = pid }
    setmetatable(handle, {
        __gc = function(t)
            helper.stop_pid(t.reader, t.pid)
        end
    })

    print(string.format("Blockchain running with pid %d", pid))
    return handle
end

local function capture_blockchain_data()
    local blockchain_data = require "blockchain.constants"
    return blockchain_data.pks, blockchain_data.endpoint
end

local Blockchain = {}
Blockchain.__index = Blockchain

function Blockchain:new(load_state)
    local blockchain = {}

    local handle = start_blockchain(load_state)
    blockchain.pks, blockchain.endpoint = capture_blockchain_data()

    blockchain._handle = handle

    setmetatable(blockchain, self)
    return blockchain
end

return Blockchain
