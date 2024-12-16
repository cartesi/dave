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

-- TODO remove this, since we're dumping/loading an "ready" anvil state.
local deploy_cmd = [[sh -c "cd %s && ./deploy_anvil.sh"]]
local function deploy_contracts(contracts_path)
    local reader = io.popen(string.format(deploy_cmd, contracts_path))
    assert(reader, "Failed to open process for deploy command: " .. deploy_cmd)
    local output = reader:read("*a")
    local success = reader:close()
    assert(success, string.format("Deploy command failed:\n%s", output))
end

return { advance_time = advance_time, deploy_contracts = deploy_contracts }
