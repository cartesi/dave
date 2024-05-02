#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_node/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local consts = require "constants"
local helper = require "utils.helper"
local time = require "utils.time"

local snapshot_dir = "/app/snapshots"
local conversion_cmd = [[
    /app/lua_node/doom_showcase/playpal2rgb %s/%04d.palette < %s/%04d.raw | convert -depth 8 -size 320x200 rgb:- %s/%04d.png& >/dev/null 2>&1
]]

local snapshot_count = 0
while(true)
do
    -- monitor if there are new snapshots created
    local i, t = 0, {}
    local pfile = io.popen(string.format("ls -dtr -1 %s/**", snapshot_dir))
    for filename in pfile:lines() do
        i = i + 1
        t[i] = filename
    end
    pfile:close()
    if snapshot_count ~= #t then
        -- for every new snapshot, load the machine and process all the frames
        local machine_path = t[snapshot_count + 1]
        if helper.exists(machine_path.."/log2_stride_count") then
            print("process snapshot of "..machine_path)

            local machine_settings = { soft_yield = true }
            local machine = cartesi.machine(machine_path, machine_settings)

            local reader = io.popen(string.format("cat %s/base_cycle", machine_path))
            local base_cycle = tonumber(reader:read())
            reader:close()
            reader = io.popen(string.format("cat %s/log2_stride", machine_path))
            local log2_stride = tonumber(reader:read())
            reader:close()
            reader = io.popen(string.format("cat %s/log2_stride_count", machine_path))
            local log2_stride_count = tonumber(reader:read())
            reader:close()

            local pixel_count = 0
            local pixels_dir = string.format("%s/pixels", machine_path)
            os.execute(string.format("mkdir -p %s", pixels_dir))

            local max_cycle = 0
            if log2_stride == 0 then
                -- small machine
                local instruction_count = arithmetic.max_uint(log2_stride_count - consts.log2_uarch_span)
                max_cycle = base_cycle + instruction_count
            else
                -- big machine
                local instruction_count = arithmetic.max_uint(log2_stride_count)
                max_cycle = base_cycle + (instruction_count << (log2_stride - consts.log2_uarch_span))
            end

            while(true)
            do
                local reason = machine:run(instruction_count)
                if reason == cartesi.BREAK_REASON_YIELDED_SOFTLY then
                    local out = io.open(string.format("%s/%04d.raw", pixels_dir, pixel_count), "wb")
                    out:write(machine:read_memory(0x82000000, 64000))
                    out:close()

                    out = io.open(string.format("%s/%04d.palette", pixels_dir, pixel_count), "wb")
                    out:write(machine:read_memory(0x82800030, 1024))
                    out:close()
                    os.execute(string.format(conversion_cmd, pixels_dir, pixel_count, pixels_dir, pixel_count, pixels_dir, pixel_count))
                    pixel_count = pixel_count + 1
                elseif reason == cartesi.BREAK_REASON_HALTED then
                    break
                end
            end
            os.execute(string.format("touch %s/done", pixels_dir))
            snapshot_count = snapshot_count + 1
            if log2_stride == 0 then
                -- leaf level of tournament
                break
            end
        end
    end
    time.sleep(10)
end
