local time = require "utils.time"
local helper = require "utils.helper"

local slots_in_an_epoch = 1
local default_account_number = 40

local blockchain_data = require "blockchain.constants"
local instance = os.getenv("TEST_INSTANCE")
local anvil_log = instance and ("anvil-" .. instance .. ".log") or "anvil.log"

-- The anvil port must be free before spawning: macOS port reuse lets a
-- stray listener coexist with ours and silently absorb traffic,
-- turning runs nondeterministic instead of failing.
local function assert_port_free(port)
    local connected = os.execute(
        string.format("bash -c 'exec 3<>/dev/tcp/127.0.0.1/%s' 2>/dev/null", port)
    )
    assert(not connected, string.format(
        "something is already listening on 127.0.0.1:%s; kill it or pick another TEST_INSTANCE",
        port))
end

-- spawn an anvil node with 40 accounts, auto-mine, and finalize block at height N-2
local function start_blockchain(anvil_load_path, anvil_dump_path)
    assert_port_free(blockchain_data.port)
    print(string.format("Starting blockchain with %d accounts...", default_account_number))

    local anvil_args = {
        "--port",
        blockchain_data.port,
        "--slots-in-an-epoch",
        slots_in_an_epoch,
        "-a",
        default_account_number,
    }

    if anvil_load_path then
        table.insert(anvil_args, "--load-state")
        table.insert(anvil_args, anvil_load_path)
    end

    if anvil_dump_path then
        table.insert(anvil_args, "--dump-state")
        table.insert(anvil_args, anvil_dump_path)
        table.insert(anvil_args, "--preserve-historical-states")
    end

    local cmd = string.format(
        [[ echo $$ ; exec anvil %s > %s 2>&1 ]],
        table.concat(anvil_args, " "),
        anvil_log
    )

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
    return blockchain_data.pks, blockchain_data.endpoint
end

local Blockchain = {}
Blockchain.__index = Blockchain

function Blockchain.new(anvil_load_path, anvil_dump_path)
    local blockchain = {}

    local handle = start_blockchain(anvil_load_path, anvil_dump_path)
    blockchain.pks, blockchain.endpoint = capture_blockchain_data()

    blockchain._handle = handle
    time.sleep(3)

    setmetatable(blockchain, Blockchain)
    return blockchain
end

return Blockchain
