#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

local cartesi = require "cartesi"

local conversion_cmd = [[
    /app/lua_poc/doom_showcase/playpal2rgb %s/%04d_%04d.palette < %s/%04d_%04d.raw | convert -depth 8 -size 320x200 rgb:- %s/%04d_%04d.png& >/dev/null 2>&1
]]

local machine_path = os.getenv("MACHINE_PATH")
local machine_settings = { soft_yield = true, htif = { no_console_putchar = true } }
local machine = cartesi.machine(machine_path, machine_settings)

local pixels_dir = "/app/pixels"
os.execute(string.format("mkdir -p %s", pixels_dir))

function output_pixel(start_cycle, end_cycle)
    -- print("wrinting to =====> " .. string.format("%s/%04d_%04d.raw", pixels_dir, start_cycle, end_cycle))
    local out = io.open(string.format("%s/%04d_%04d.raw", pixels_dir, start_cycle, end_cycle), "wb")
    out:write(machine:read_memory(0x82000000, 64000))
    out:close()

    out = io.open(string.format("%s/%04d_%04d.palette", pixels_dir, start_cycle, end_cycle), "wb")
    out:write(machine:read_memory(0x82800030, 1024))
    out:close()
    os.execute(string.format(conversion_cmd, pixels_dir, start_cycle, end_cycle, pixels_dir, start_cycle, end_cycle, pixels_dir, start_cycle, end_cycle))
end

while(true)
do
    local start_cycle = machine:read_mcycle()
    local reason = machine:run(1 << 48)
    if reason == cartesi.BREAK_REASON_YIELDED_SOFTLY then
        local end_cycle = machine:read_mcycle()
        output_pixel(start_cycle, end_cycle)
    elseif reason == cartesi.BREAK_REASON_HALTED then
        local end_cycle = 0
        output_pixel(start_cycle, end_cycle)
        break
    end
end
