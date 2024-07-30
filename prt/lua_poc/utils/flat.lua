local bint = require 'utils.bint' (256) -- use 256 bits integers

local m = {}

local function print_table(object)
    if type(object) == "table" then
        for k, v in pairs(object) do
            print(string.format("\"%s\":{", k))
            print_table(v)
            print(string.format("},", k))
        end
    else
        print(string.format("\"%s\"", object))
    end
end

-- this is a very specific flatten implementation for tournament tables
-- it handles circular references and all custom classes being used
local function flatten_recursive(object, flat_tables)
    if type(object) == "table" then
        local id
        if next(object) == nil then
            return "nil"
            -- object is empty
        elseif object.address then
            -- tournament table
            id = tostring(object.address)
        elseif object.match_id_hash then
            -- match table
            id = tostring(object.match_id_hash)
        elseif object.hex_string then
            -- merkle table, treat as hex_string
            return object:hex_string()
        elseif bint.isbint(object) then
            -- bint, treat as string
            return tostring(object)
        elseif #object > 0 then
            -- this is an array
            local flatten = {}
            for i = 1, #object do
                flatten[i] = flatten_recursive(object[i], flat_tables)
            end
            return flatten
        else
            -- other kind of tables
            id = ("%p"):format(object)
        end

        if not flat_tables[id] then
            local flat_table = {}
            flat_tables[id] = flat_table
            for k, v in pairs(object) do
                -- key must be string
                flat_table[tostring(k)] = flatten_recursive(v, flat_tables)
            end
        end

        if object.address then
            -- tournament table, return only id to avoid circular references
            return id
        else
            return flat_tables[id]
        end
    else
        -- primitive types, return directly
        return object
    end
end

function m.flatten(object)
    local flat_tables = {}
    local flat_object = flatten_recursive(object, flat_tables)
    -- print_table(flat_tables)
    return {
        flat_tables = flat_tables,
        flat_object = flat_object,
    }
end

local function create_table_stubs(flat_tables)
    local tables = {}
    for id in pairs(flat_tables) do
        tables[id] = {}
    end
    return tables
end

local function inflate_object(flat_object, tables)
    if type(flat_object) == "table" then
        local id = assert(flat_object.id, "missing id")
        return tables[id]
    else
        return flat_object
    end
end

local function link_tables(flat_tables, tables)
    for id, flat_table in pairs(flat_tables) do
        for _, pair in ipairs(flat_table) do
            local k = inflate_object(pair.key, tables)
            local v = inflate_object(pair.value, tables)
            tables[id][k] = v
        end
    end
end

function m.inflate(t)
    local tables = create_table_stubs(t.flat_tables)
    link_tables(t.flat_tables, tables)
    return inflate_object(t.flat_object, tables)
end

return m
