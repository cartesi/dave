local helper = require "utils.helper"

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

function Dave:new(machine_path, app_address, sleep_duration, verbosity, trace_level)
    local n = {}
    os.execute "rm -rf _state && mkdir _state"

    local handle = start_dave_node(machine_path, app_address, "_state/", sleep_duration, verbosity, trace_level)

    n._handle = handle

    setmetatable(n, self)
    return n
end

return Dave
