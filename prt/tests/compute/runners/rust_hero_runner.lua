-- Required Modules
local blockchain_consts = require "blockchain.constants"
local helper = require "utils.helper"

local function set_int_handler(reader, pid)
    local signal = require("posix.signal")
    signal.signal(signal.SIGINT, function()
        helper.stop_pid(reader, pid)
        os.exit(1)
    end)
end

local function get_hero_nonce()
    local hero_nonce_cmd = string.format("cast nonce %s --rpc-url %s",
        blockchain_consts.hero_address, blockchain_consts.endpoint)
    local process = io.popen(hero_nonce_cmd)                 -- Execute the command
    assert(process, "Failed to open process for hero nonce") -- Check if process is nil
    local output = process:read("*a")                        -- Read all output
    local success, _, code = process:close()                 -- Close the process
    assert(success, string.format("Hero nonce command failed:\n%d", code))

    -- Convert the output to an integer
    local nonce = tonumber(output:match("%d+")) -- Extract the first number from the output
    return nonce
end

-- The Rust Compute reacts once and exits, the coroutine periodically spawn a new process until the tournament ends
local function create_react_once_runner(player_id, machine_path)
    local rust_compute_cmd = string.format(
        [[sh -c "echo $$ ; exec env MACHINE_PATH='%s' RUST_LOG='info' \
    ./cartesi-prt-compute 2>&1 | tee -a honest.log"]],
        machine_path)

    return coroutine.create(function()
        while true do
            local tx_count = get_hero_nonce()
            local reader = io.popen(rust_compute_cmd)
            assert(reader, "Failed to open process for Rust compute: " .. rust_compute_cmd)
            local hero_pid = tonumber(reader:read())

            while true do
                local output = reader:read()
                if not output then break end
                helper.log_color(player_id, output)
            end

            local success, _, code = reader:close()
            assert(success, string.format("Rust compute command failed to close:\n%d", code))

            if helper.exists("/root/prt/tests/compute/finished") then
                break
            end

            local idle = tx_count == get_hero_nonce()
            coroutine.yield({ idle = idle, finished = false })
        end
    end)
end

-- The Rust Compute reacts in a loop until the tournament ends, the coroutine pulls its state periodically until the process ends
local function create_runner(player_id, machine_path)
    local hero_react_interval = 3
    local rust_compute_cmd = string.format(
        [[sh -c "echo $$ ; exec env INTERVAL='%d' MACHINE_PATH='%s' RUST_LOG='info' \
    ./cartesi-prt-compute 2>&1 | tee honest.log"]],
        hero_react_interval, machine_path)

    return coroutine.create(function()
        local start_time = os.time()
        local tx_count = get_hero_nonce()
        local reader = io.popen(rust_compute_cmd)
        assert(reader, "Failed to open process for Rust compute: " .. rust_compute_cmd)
        local hero_pid = tonumber(reader:read())

        set_int_handler(reader, hero_pid)

        print(string.format("Hero running with pid %d", hero_pid))
        local prev_msg = false

        while true do
            if prev_msg then
                helper.log_color(player_id, prev_msg)
                prev_msg = false
            end

            prev_msg = helper.log_to_ts(player_id, reader, start_time + hero_react_interval)

            start_time = os.time()
            if not helper.is_pid_alive(hero_pid) then
                break
            end

            local new_tx_count = get_hero_nonce()
            local idle = tx_count == new_tx_count
            tx_count = new_tx_count
            coroutine.yield({ idle = idle, finished = false })
        end

        local success, _, code = reader:close()
        assert(success, string.format("Rust compute command failed to close:\n%d", code))
    end)
end

return { create_runner = create_runner, create_react_once_runner = create_react_once_runner }
