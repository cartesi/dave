local m = {}

local function hex_from_bin(bin)
    assert(bin:len() == 32)
    return "0x" .. (bin:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

local function flatten_recursive (object, flat_tables)
    if type(object) == "table" then
        local id = ("%p"):format(object)
        if flat_tables[id] == nil then
            local flat_table = {}
            flat_tables[id] = flat_table
            for k, v in pairs(object) do
                if k == "digest"
                then
                    v = hex_from_bin(v)
                end
                table.insert(flat_table, {
                    key = flatten_recursive(k, flat_tables),
                    value = flatten_recursive(v, flat_tables),
                })
            end
        end
        return { id = id }
    else
        return object
    end
end

function m.flatten (object)
    local flat_tables = {}
    local flat_object = flatten_recursive(object, flat_tables)
    return {
        flat_tables = flat_tables,
        flat_object = flat_object,
    }
end

local function create_table_stubs (flat_tables)
    local tables = {}
    for id in pairs(flat_tables) do
        tables[id] = {}
    end
    return tables
end

local function inflate_object (flat_object, tables)
    if type(flat_object) == "table" then
        local id = assert(flat_object.id, "missing id")
        return tables[id]
    else
        return flat_object
    end
end

local function link_tables (flat_tables, tables)
    for id, flat_table in pairs(flat_tables) do
        for i, pair in ipairs(flat_table) do
            local k = inflate_object(pair.key, tables)
            local v = inflate_object(pair.value, tables)
            tables[id][k] = v
        end
    end
end

function m.inflate (t)
    local tables = create_table_stubs(t.flat_tables)
    link_tables(t.flat_tables, tables)
    return inflate_object(t.flat_object, tables)
end

return m
