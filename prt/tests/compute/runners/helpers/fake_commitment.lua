local consts = require "computation.constants"
local MerkleBuilder = require "cryptography.merkle_builder"
local Hash = require "cryptography.hash"
local CommitmentBuilder = require "computation.commitment"

local FakeCommitmentBuilder = {}
FakeCommitmentBuilder.__index = FakeCommitmentBuilder

local function build_zero_uarch()
    local builder = MerkleBuilder:new()

    -- all uarch states are zero including the reset state
    builder:add(Hash.zero, consts.uarch_span + 1)

    return builder:build()
end

local function shallow_copy(orig)
    local copy = {}
    for orig_key, orig_value in next, orig, nil do
        copy[orig_key] = orig_value
    end
    setmetatable(copy, getmetatable(orig))
    return copy
end

local function get_fake_hash(log2_stride, uarch_zero)
    if log2_stride == 0 then
        return uarch_zero
    else
        return Hash.zero
    end
end

local function rebuild_nested_trees(fake_builder)
    for i = 1, #fake_builder.leafs do
        -- if a leaf is also a tree, rebuild it to properly update `Hash` internal states
        local l = fake_builder.leafs[i].hash
        if l.leafs then
            local builder = MerkleBuilder:new()
            builder.leafs = l.leafs
            builder:build()
        end
    end
end

local function build_commitment(builder, base_cycle, level, log2_stride, log2_stride_count)
    -- take snapshot of the internal states of `Hash`
    -- local internalized_hashes = Hash.get_internal()
    -- local new_internalized_hashes = shallow_copy(internalized_hashes)

    local c = builder:build(base_cycle, level, log2_stride, log2_stride_count)
    -- restore the internal states of `Hash` from previous snapshot
    -- this is to avoid the dishonest player to react on the honest behave
    -- Hash.set_internal(new_internalized_hashes)

    return c
end

local function build_fake_commitment(commitment, fake_index, log2_stride, uarch_zero)
    local fake_builder = MerkleBuilder:new()
    -- copy leafs by key-value pairs recursively, otherwise it'll pollute the original commitment leafs
    fake_builder.leafs = shallow_copy(commitment.leafs)

    local fake_hash = get_fake_hash(log2_stride, uarch_zero)
    local leaf_index = math.max(#commitment.leafs - fake_index + 1, 1)
    local old_leaf = fake_builder.leafs[leaf_index]

    fake_builder.leafs[leaf_index] = { hash = fake_hash, accumulated_count = old_leaf.accumulated_count }
    rebuild_nested_trees(fake_builder)

    return fake_builder:build(commitment.implicit_hash)
end

function FakeCommitmentBuilder:new(machine_path)
    local c = {
        fake_index = 1,
        builder = CommitmentBuilder:new(machine_path),
        fake_commitments = {},
        uarch_zero = build_zero_uarch()
    }
    setmetatable(c, self)
    return c
end

function FakeCommitmentBuilder:build(base_cycle, level, log2_stride, log2_stride_count)
    if not self.fake_commitments[level] then
        self.fake_commitments[level] = {}
    end
    if not self.fake_commitments[level][base_cycle] then
        self.fake_commitments[level][base_cycle] = {}
    end
    if self.fake_commitments[level][base_cycle][self.fake_index] then
        return self.fake_commitments[level][base_cycle][self.fake_index]
    end

    local commitment = build_commitment(self.builder, base_cycle, level, log2_stride, log2_stride_count)
    -- function caller should set `self.fake_index` properly from outside to generate different fake commitment
    -- the fake commitments are not guaranteed to be unique if there are not many leafs (short computation)
    local fake_commitment = build_fake_commitment(commitment, self.fake_index, log2_stride, self.uarch_zero)

    self.fake_commitments[level][base_cycle][self.fake_index] = fake_commitment
    return fake_commitment
end

return FakeCommitmentBuilder
