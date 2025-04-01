local function hex_from_bin_n(bin)
    return "0x" .. (bin:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

local function hex_from_bin(bin)
    assert(bin:len() == 32)
    return hex_from_bin_n(bin)
end

local function bin_from_hex_n(hex)
    local h = assert(hex:match("0x(%x+)"), hex)
    return (h:gsub('..', function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function bin_from_hex(hex)
    assert(hex:len() == 66, string.format("%s %d", hex, hex:len()))
    return bin_from_hex_n(hex)
end




return {
    hex_from_bin = hex_from_bin,
    bin_from_hex = bin_from_hex,
    hex_from_bin_n = hex_from_bin_n,
    bin_from_hex_n = bin_from_hex_n
}
