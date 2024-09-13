local function find_chunk(name)
    local x, err = package.searchpath(name, package.path)

    if err then
        error(string.format("module '%s' not found\n", name))
    end

    return x
end

local function new_scoped_require(env)
    local new_env = { bananas = "bananas" }
    setmetatable(new_env, { __index = env })
    local loaded = {}

    local function scoped_require(name)
        if loaded[name] == nil then
            local path = find_chunk(name)

            local chunk, err = loadfile(path, "t", new_env)
            if not chunk then error(err) end

            local result = { chunk(name) }
            loaded[name] = result
        end

        return table.unpack(loaded[name])
    end

    new_env.require = scoped_require

    return scoped_require
end


return new_scoped_require
