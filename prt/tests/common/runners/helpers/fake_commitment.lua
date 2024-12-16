local consts = require "computation.constants"
local MerkleBuilder = require "cryptography.merkle_builder"
local Hash = require "cryptography.hash"
local new_scoped_require = require "test_utils.scoped_require"

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

local uarch_zero = build_zero_uarch()

local function get_fake_hash(log2_stride)
    if log2_stride == 0 then
        return uarch_zero
    else
        return Hash.zero
    end
end

local function update_scope_of_hashes(leafs)
    -- the leafs are from foreign scope, thus we need to manually call the `Hash` in our scope
    -- to have the internal states working
    for i = 1, #leafs do
        -- update the Hash state from another scope
        local l = leafs[i].hash
        if l.digest then
            -- l is Hash type
            local h = Hash:from_digest(l.digest)
            leafs[i].hash = h
        elseif l.leafs then
            -- l is MerkleTree type
            update_scope_of_hashes(l.leafs)
        end
    end
end

local function rebuild_nested_trees(leafs)
    for i = 1, #leafs do
        -- if a leaf is also a tree, rebuild it to properly update `Hash` internal states
        -- i.e. the relationship between parents and children
        local l = leafs[i].hash
        if l.leafs then
            local builder = MerkleBuilder:new()
            builder.leafs = l.leafs
            leafs[i].hash = builder:build()
        end
    end
end

local function build_commitment(cached_commitments, machine_path, snapshot_dir, base_cycle, level, log2_stride,
                                log2_stride_count, inputs)
    -- the honest commitment builder should be operated in an isolated env
    -- to avoid side effects to the strategy behavior

    if not cached_commitments[level] then
        cached_commitments[level] = {}
    elseif cached_commitments[level][base_cycle] then
        return cached_commitments[level][base_cycle]
    end

    local c = coroutine.create(function()
        local scoped_require = new_scoped_require(_ENV)
        local CommitmentBuilder = scoped_require "computation.commitment"

        local builder = CommitmentBuilder:new(machine_path, snapshot_dir)
        local commitment = builder:build(base_cycle, level, log2_stride, log2_stride_count, inputs)
        coroutine.yield(commitment)
    end)

    local success, ret = coroutine.resume(c)
    if not success then
        error(string.format("commitment coroutine fail to resume with error: %s", ret))
    else
        cached_commitments[level][base_cycle] = ret
        return ret
    end
end

local function build_fake_commitment(commitment, fake_index, log2_stride)
    local fake_builder = MerkleBuilder:new()
    fake_builder.leafs = shallow_copy(commitment.leafs)

    local fake_hash = get_fake_hash(log2_stride)
    local leaf_index = math.max(#commitment.leafs - fake_index + 1, 1)
    for i = leaf_index, #commitment.leafs do
        local old_leaf = fake_builder.leafs[i]
        fake_builder.leafs[i] = { hash = fake_hash, accumulated_count = old_leaf.accumulated_count }
    end

    update_scope_of_hashes(fake_builder.leafs)
    rebuild_nested_trees(fake_builder.leafs)

    local implicit_hash = Hash:from_digest(commitment.implicit_hash.digest)
    return fake_builder:build(implicit_hash)
end

function FakeCommitmentBuilder:new(machine_path, root_commitment, snapshot_dir)
    -- receive honest root commitment from main process
    local commitments = { [0] = { [0] = root_commitment } }

    local c = {
        fake_index = false,
        machine_path = machine_path,
        snapshot_dir = snapshot_dir,
        fake_commitments = {},
        commitments = commitments
    }
    setmetatable(c, self)
    return c
end

function FakeCommitmentBuilder:build(base_cycle, level, log2_stride, log2_stride_count, inputs)
    -- function caller should set `self.fake_index` properly before calling this function
    -- the fake commitments are not guaranteed to be unique if there are not many leafs (short computation)
    -- `self.fake_index` is reset and the end of a successful call to ensure the next caller must set it again.
    assert(self.fake_index)
    if not self.fake_commitments[level] then
        self.fake_commitments[level] = {}
    end
    if not self.fake_commitments[level][base_cycle] then
        self.fake_commitments[level][base_cycle] = {}
    end
    if self.fake_commitments[level][base_cycle][self.fake_index] then
        return self.fake_commitments[level][base_cycle][self.fake_index]
    end

    local commitment = build_commitment(self.commitments, self.machine_path, self.snapshot_dir, base_cycle, level,
        log2_stride,
        log2_stride_count,
        inputs)
    print("honest commitment", commitment)
    local fake_commitment = build_fake_commitment(commitment, self.fake_index, log2_stride)

    self.fake_commitments[level][base_cycle][self.fake_index] = fake_commitment
    return fake_commitment
end

return FakeCommitmentBuilder
