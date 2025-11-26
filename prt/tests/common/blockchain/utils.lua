local T = {}

T.exec = function(fmt, ...)
    local cmd = string.format(fmt, ...)
    local reader = io.popen(cmd)
    assert(reader, "`popen` returned nil reader")

    local data = reader:read("*a")
    local success, _, code = reader:close()
    assert(success, string.format("command [[%s]] failed on close:\n%d", cmd, code))
    return data:gsub("\n$", "") -- remove trailing newline from data
end

T.get_address = function(endpoint, pk)
    return T.exec([[cast wallet -r "%s" address "%s"]], endpoint, pk)
end

T.set_balance = function(endpoint, account, value)
    return T.exec([[cast rpc -r "%s" anvil_setBalance "%s" "%s"]], endpoint, account, value)
end

T.get_balance = function(endpoint, account)
    return T.exec([[cast balance -r "%s" "%s"]], endpoint, account)
end

T.auto_impersonate = function(endpoint, yes)
    return T.exec([[cast rpc -r "%s" anvil_autoImpersonateAccount %s]], endpoint, yes)
end

T.advance_time = function(endpoint, blocks)
    return T.exec([[cast rpc -r "%s" anvil_mine %d]], endpoint, blocks)
end

return T
