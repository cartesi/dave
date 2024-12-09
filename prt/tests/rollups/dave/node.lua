local helper = require "utils.helper"

local function start_dave_node(machine_path, db_path, sleep_duration, verbosity, trace_level)
    local cmd = string.format(
        [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' PATH_TO_DB='%s' \
        SLEEP_DURATION=%d RUST_LOG=%s RUST_BACKTRACE=%s \
        ./dave-rollups > dave.log 2>&1"]],
        machine_path, db_path, sleep_duration, verbosity, trace_level)

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

function Dave:new(machine_path, sleep_duration, verbosity, trace_level)
    local n = {}

    local handle = start_dave_node(machine_path, "./dave.db", sleep_duration, verbosity, trace_level)

    n._handle = handle

    setmetatable(n, self)
    return n
end

return Dave
