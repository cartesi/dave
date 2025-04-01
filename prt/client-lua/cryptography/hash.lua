local keccak = require "cartesi".keccak
local conversion = require "utils.conversion"

local interned_hashes = {}
local iterateds = {}

local Hash = {}
Hash.__index = Hash

function Hash:from_digest(digest)
    assert(type(digest) == "string", digest:len() == 32)

    local x = interned_hashes[digest]
    if x then return x end

    local h = { digest = digest }
    iterateds[h] = { h }
    setmetatable(h, self)
    interned_hashes[digest] = h
    return h
end

function Hash:from_digest_hex(digest_hex)
    assert(type(digest_hex) == "string", digest_hex:len() == 66)
    local digest = conversion.bin_from_hex(digest_hex)
    return self:from_digest(digest)
end

function Hash:from_data(data)
    local digest = keccak(data)
    return self:from_digest(digest)
end

function Hash:join(other_hash)
    assert(Hash:is_of_type_hash(other_hash))

    local digest = keccak(self.digest, other_hash.digest)
    local ret = Hash:from_digest(digest)
    ret.left = self
    ret.right = other_hash
    return ret
end

function Hash:children()
    local left, right = self.left, self.right
    if left and right then
        return true, left, right
    else
        return false
    end
end

function Hash:iterated_merkle(level)
    level = level + 1
    local iterated = iterateds[self]

    local ret = iterated[level]
    if ret then return ret end

    local i = #iterated -- at least 1
    local highest_level = iterated[i]
    while i < level do
        highest_level = highest_level:join(highest_level)
        i = i + 1
        iterated[i] = highest_level
    end

    return highest_level
end

function Hash:hex_string()
    return conversion.hex_from_bin(self.digest)
end

Hash.__eq = function(x, y)
    return x:hex_string() == y:hex_string()
end

Hash.__tostring = function(x)
    return conversion.hex_from_bin(x.digest)
end

local zero_bytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000"
local zero_hash = Hash:from_digest_hex(zero_bytes32)

Hash.zero = zero_hash

function Hash:is_zero()
    return self == zero_hash
end

function Hash:is_of_type_hash(x)
    return getmetatable(x) == self
end

return Hash
