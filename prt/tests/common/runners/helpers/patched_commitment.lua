local CommitmentBuilder = require "computation.commitment"
local bint256 = require("utils.bint")(256)

local PatchedCommitmentBuilder = {}
PatchedCommitmentBuilder.__index = PatchedCommitmentBuilder

local function validate_patch(patch)
    patch.log2size = patch.log2size or 0
    assert(patch.hash)
    assert(patch.log2size == 0)
    assert(patch.meta_cycle)
    assert(patch.meta_cycle > 0)
    patch.meta_cycle = bint256.fromuinteger(patch.meta_cycle)

    -- first log2size bits must be zero
    local mask = (bint256.one() << patch.log2size) - 1
    assert((mask & patch.meta_cycle):iszero(), "patch meta_cycle and log2size not compatible!")

    return patch
end

local function validate_patches(patches)
    for _, patch in ipairs(patches) do
        validate_patch(patch)
    end

    return patches
end

local function filter_map_patches(patches, base_cycle, log2_stride, log2_stride_count)
    local t = {}
    for _, patch in ipairs(patches) do
        local span = bint256.one() << (log2_stride_count + log2_stride)
        local mask = (bint256.one() << log2_stride) - 1
        if (patch.meta_cycle & mask):iszero() and -- alignment; first bits are zero
            patch.meta_cycle > base_cycle and -- meta_cycle is within lower bound
            patch.meta_cycle <= base_cycle + span -- meta_cycle is within upper bounds
        then
            local position = ((patch.meta_cycle - base_cycle) >> log2_stride) - 1
            local p = {
                hash = patch.hash,
                position = position:touinteger(),
                log2size = patch.log2size, -- assumed to be 0 for now, TODO
            }
            table.insert(t, p)
        end
    end

    return t
end

function PatchedCommitmentBuilder:new(machine_path, root_commitment, inputs, patches, snapshot_dir)
    validate_patches(assert(patches))
    local commitment_builder = CommitmentBuilder:new(machine_path, inputs, root_commitment, snapshot_dir)

    local c = {
        commitment_builder = commitment_builder,
        patches = patches,
    }
    setmetatable(c, self)
    return c
end

function PatchedCommitmentBuilder:build(base_cycle, level, log2_stride, log2_stride_count)
    local commitment = self.commitment_builder:build(base_cycle, level, log2_stride, log2_stride_count)
    local transformed_patches = filter_map_patches(self.patches, base_cycle, log2_stride, log2_stride_count)
    if #transformed_patches == 0 then print "ZERO PATCHES APPLIED" end
    return commitment:clone_and_patch(transformed_patches)
end

return PatchedCommitmentBuilder
