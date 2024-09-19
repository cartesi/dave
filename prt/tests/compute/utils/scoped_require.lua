local function find_path(name)
    local x, err1 = package.searchpath(name, package.path)

    if not err1 then
        return "lua", x
    end

    local y, err2 = package.searchpath(name, package.cpath)

    if not err2 then
        return "clib", y
    end

    error(string.format("module '%s' not found\n", name))
end

local function custom_require_c(library_path, library_name)
    -- Load the library
    local mylib = package.loadlib(library_path, "luaopen_" .. library_name)

    local module, err
    if not mylib then
        module = nil
        err = "Failed to load library: " .. library_path
    else
        -- Call the library's initialization function
        module = mylib()
        err = false
    end

    return module, err
end

local function new_scoped_require(env)
    local new_env = { bananas = "bananas" }
    setmetatable(new_env, { __index = env })
    local loaded = {}

    local function scoped_require(name)
        if not loaded[name] then
            local module_type, path = find_path(name)

            local chunk, err, result
            if module_type == "lua" then
                chunk, err = loadfile(path, "bt", new_env)
            elseif module_type == "clib" then
                chunk, err = custom_require_c(path, name)
            end

            if not chunk then error(err) end

            if module_type == "lua" then
                result = { chunk(name) }
            elseif module_type == "clib" then
                result = { chunk }
            end

            loaded[name] = result
        end

        return table.unpack(loaded[name])
    end

    new_env.require = scoped_require

    return scoped_require
end


return new_scoped_require
