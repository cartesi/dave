local Hash = require "cryptography.hash"
local MerkleBuilder = require "cryptography.merkle_builder"
local Machine = require "computation.machine"
local helper = require "utils.helper"
local time = require "utils.time"

local ANVIL_KEY_7 = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"

local function start_dave_node(machine_path, app_address, db_path, sleep_duration, verbosity, trace_level)
    local cmd = string.format(
        [[echo $$ ; exec env MACHINE_PATH='%s' APP_ADDRESS='%s' STATE_DIR='%s' \
        RUST_BACKTRACE='%s' RUST_LOG='info',cartesi_prt_core='%s',rollups_epoch_manager='%s' \
        ../../../target/debug/cartesi-rollups-prt-node --sleep-duration-seconds %s pk --web3-private-key %s > dave.log 2>&1]],
        machine_path, app_address, db_path, trace_level, verbosity, verbosity, sleep_duration, ANVIL_KEY_7
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

    print(string.format("Dave node running with pid %d", pid))
    return handle
end

local Dave = {}
Dave.__index = Dave

function Dave:new(machine_path, app_address, sender, sleep_duration, verbosity, trace_level)
    -- trace, debug, info, warn, error
    verbosity = verbosity or os.getenv("VERBOSITY") or 'debug'

    -- 0, 1, full
    trace_level = trace_level or os.getenv("TRACE_LEVEL") or 'full'


    local n = { initial_machine_path = assert(machine_path), sender = sender }
    os.execute "rm -rf _state && mkdir _state"

    local handle = start_dave_node(machine_path, app_address, "_state/", sleep_duration, verbosity, trace_level)

    n._handle = handle

    setmetatable(n, Dave)
    return n
end

local function db_exists(epoch_index)
    local db_path = string.format("./_state/%d/db", epoch_index)
    return helper.exists(db_path)
end

local ROOT_LEAFS_QUERY = [[
sqlite3 -readonly ./_state/%d/db \
'SELECT repetitions, HEX(leaf) FROM leafs WHERE level=0 ORDER BY leaf_index ASC' 2>&1
]]
function Dave:root_commitment(epoch_index)
    local query = function()
        assert(db_exists(epoch_index), string.format("db %d doesn't exist ", epoch_index))

        local builder = MerkleBuilder:new()
        local machine = Machine:new_from_path(self:machine_path(epoch_index))
        local initial_state = machine:state()
        local query = string.format(ROOT_LEAFS_QUERY, epoch_index)
        local handle = io.popen(query)
        assert(handle)
        local rows = handle:read "*a"
        handle:close()

        if rows:find "Error" then
            error(string.format("Read leafs failed:\n%s", rows))
        end

        -- Iterate over each line in the input data
        for line in rows:gmatch("[^\n]+") do
            local repetitions, leaf = line:match(
                "([^|]+)|([^|]+)")
            -- Convert values to appropriate types
            repetitions = tonumber(assert(repetitions))
            leaf = Hash:from_digest_hex("0x" .. leaf)
            builder:add(leaf, repetitions)
        end

        return initial_state, builder:build(initial_state.root_hash)
    end

    local initial_state, commitment
    time.sleep_until(function()
        self.sender:advance_blocks(1)
        local ok
        ok, initial_state, commitment = pcall(query)
        return ok
    end, 5)

    return initial_state, commitment
end

local MACHINE_PATH_QUERY = [[
sqlite3 -readonly ./_state/db.sqlite3 \
'SELECT s.file_path FROM epoch_snapshot_info AS e JOIN machine_state_snapshots AS s ON s.state_hash = e.state_hash WHERE e.epoch_number = %d' 2>&1]]
function Dave:machine_path(epoch_index)
    local query = function()
        assert(db_exists(epoch_index), string.format("db %d doesn't exist ", epoch_index))

        local cmd = string.format(MACHINE_PATH_QUERY, epoch_index)
        local handle = io.popen(cmd)
        assert(handle)
        local path = handle:read()
        local tail = handle:read "*a"
        handle:close()
        if path:find "Error" or tail:find "Error" then
            error(string.format("Read machine path failed:\n%s", path))
        end
        return path
    end

    local path
    time.sleep_until(function()
        self.sender:advance_blocks(1)
        local ok
        ok, path = pcall(query)
        return ok
    end, 5)

    return path
end

local INPUTS_QUERY =
[[sqlite3 -readonly ./_state/%d/db 'select HEX(input)
from inputs ORDER BY input_index ASC' 2>&1]]
function Dave:inputs(epoch_index)
    local query = function()
        assert(db_exists(epoch_index), string.format("db %d doesn't exist ", epoch_index))

        local handle = io.popen(string.format(INPUTS_QUERY, epoch_index))
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

    local inputs
    time.sleep_until(function()
        self.sender:advance_blocks(1)
        local ok
        ok, inputs = pcall(query)
        return ok
    end, 5)

    return assert(inputs)
end

return Dave
