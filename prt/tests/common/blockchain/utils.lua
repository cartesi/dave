local cast_advance_template = [[
cast rpc -r "%s" anvil_mine %d
]]

local function advance_time(blocks, endpoint)
    local cmd = string.format(
        cast_advance_template,
        endpoint,
        blocks
    )

    local handle = io.popen(cmd)
    assert(handle)
    local ret = handle:read "*a"
    handle:close()

    if ret:find "Error" then
        error(string.format("Advance time `%d`s failed:\n%s", blocks, ret))
    end
end

return { advance_time = advance_time }
