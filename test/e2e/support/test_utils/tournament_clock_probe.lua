local Hash = require "cryptography.hash"

local TournamentClockProbe = {}
TournamentClockProbe.__index = TournamentClockProbe

-- This white-box probe belongs only to the clock-engineering E2E fixture.
-- Its slot follows the current implementation and is not a compatibility API.
local CLOCKS_SLOT = 9

local function slot_hash(index)
    return Hash:from_digest_hex(
        "0x" .. string.format("%064x", index)
    )
end

local function mapping_slot(key_hash, slot_index)
    return key_hash:join(slot_hash(slot_index)):hex_string()
end

function TournamentClockProbe.new(endpoint)
    return setmetatable({ endpoint = assert(endpoint) }, TournamentClockProbe)
end

function TournamentClockProbe:latest_block_number()
    local command = string.format(
        'cast block latest --rpc-url "%s" 2>&1',
        self.endpoint
    )
    local handle = assert(io.popen(command))
    local output = handle:read "*a"
    handle:close()
    if output:find "Error" or output:find "error" then
        error(string.format("Cast block failed:\n%s", output))
    end
    return assert(
        tonumber(output:match("number%s+(%d+)")),
        "cast block returned no block number"
    )
end

function TournamentClockProbe:_read(address, slot)
    local command = string.format(
        'cast storage --rpc-url "%s" "%s" "%s" 2>&1',
        self.endpoint,
        address,
        slot
    )
    local handle = assert(io.popen(command))
    local output = handle:read "*a"
    handle:close()
    if output:find "Error" or output:find "error" then
        error(string.format("Storage read `%s` failed:\n%s", slot, output))
    end
    local word = output:match("(0x%x+)")
    assert(word and #word == 66, "storage read returned no 32-byte word")
    return word
end

function TournamentClockProbe:read_clocks(address, commitments)
    local block_number = self:latest_block_number()
    local clocks = {}
    for index, commitment in ipairs(commitments) do
        local word = self:_read(
            address,
            mapping_slot(commitment, CLOCKS_SLOT)
        ):sub(3)
        clocks[index] = {
            allowance = tonumber(word:sub(-16), 16),
            last_resume = tonumber(word:sub(-32, -17), 16),
            block_number = block_number,
        }
    end
    assert(self:latest_block_number() == block_number,
        "chain advanced while reading commitment clocks")
    return table.unpack(clocks)
end

return TournamentClockProbe
