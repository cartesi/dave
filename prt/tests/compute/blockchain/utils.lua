local cast_advance_template = [[
cast rpc -r "%s" evm_increaseTime %d
]]

local function advance_time(seconds, endpoint)
    local cmd = string.format(
        cast_advance_template,
        endpoint,
        seconds
    )

    local handle = io.popen(cmd)
    assert(handle)
    local ret = handle:read "*a"
    handle:close()

    if ret:find "Error" then
        error(string.format("Advance time `%d`s failed:\n%s", seconds, ret))
    end
end

local deploy_cmd = [[sh -c "cd ../../contracts && ./deploy_anvil.sh"]]
local function deploy_contracts()
    local reader = io.popen(deploy_cmd)
    return assert(reader):read()
end

return { advance_time = advance_time, deploy_contracts = deploy_contracts }
