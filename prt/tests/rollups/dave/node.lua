local helper = require "utils.helper"

local function start_dave_node(machine_path, db_path, sleep_duration, verbosity, trace_level)
    local cmd = string.format(
        [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' STATE_DIR='%s' \
        SLEEP_DURATION=%d RUST_BACKTRACE='%s' \
        RUST_LOG='none',cartesi_prt_core='%s',rollups_prt_runner='%s',rollups_epoch_manager='%s' \
        ../../../target/debug/dave-rollups > dave.log 2>&1"]],
        machine_path, db_path, sleep_duration, trace_level, verbosity, verbosity, verbosity
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

function Dave:new(machine_path, sleep_duration, verbosity, trace_level)
    local n = {}
    os.execute "rm -rf _state && mkdir _state"

    local handle = start_dave_node(machine_path, "_state/", sleep_duration, verbosity, trace_level)

    n._handle = handle

    setmetatable(n, self)
    return n
end

return Dave
