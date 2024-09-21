local helper = require "utils.helper"

local default_account_number = 40

local function start_blockchain()
    print(string.format("Starting blockchain with %d accounts...", default_account_number))

    local cmd = string.format([[sh -c "echo $$ ; exec anvil --block-time 1 -a %d > anvil.log 2>&1"]],
        default_account_number)

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

function Blockchain:new()
    local blockchain = {}

    local handle = start_blockchain()
    blockchain.pks, blockchain.endpoint = capture_blockchain_data()

    blockchain._handle = handle

    setmetatable(blockchain, self)
    return blockchain
end

return Blockchain
