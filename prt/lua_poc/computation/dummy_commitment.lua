local MerkleBuilder = require "cryptography.merkle_builder"
local Hash = require "cryptography.hash"

local DummyCommitmentBuilder = {}
DummyCommitmentBuilder.__index = DummyCommitmentBuilder

function DummyCommitmentBuilder:new(initial_hash, seed, second_state)
    local c = { initial_hash = initial_hash, seed = seed, second_state = second_state }
    setmetatable(c, self)
    return c
end

function DummyCommitmentBuilder:build(_, _, log2_stride, log2_stride_count)
    local builder = MerkleBuilder:new()
    local seed = self.seed or Hash.zero
    if log2_stride == 0 and self.second_state then
        builder:add(self.second_state)
        builder:add(seed, (1 << log2_stride_count) - 1)
    else
        builder:add(seed, 1 << log2_stride_count)
    end
    -- local commitment = Hash.zero:iterated_merkle(consts.heights[level])
    return builder:build(self.initial_hash)
end

return DummyCommitmentBuilder
