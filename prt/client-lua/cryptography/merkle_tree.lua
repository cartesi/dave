local arithmetic = require "utils.arithmetic"
local bint256 = require("utils.bint")(256)
local Hash = require "cryptography.hash"

local MerkleTree = {}
MerkleTree.__index = MerkleTree

function MerkleTree:new(leafs, root_hash, log2size, implicit_hash)
    local height = log2size

    -- assert types
    if Hash:is_of_type_hash(leafs[1].hash) then
        for _,v in ipairs(leafs) do
            assert(Hash:is_of_type_hash(v.hash))
        end
    else
        local subtree_height = assert(leafs[1].hash.height)
        for _,v in ipairs(leafs) do
            local tree = v.hash
            assert(subtree_height == assert(tree.height))
        end
        height = height + subtree_height
    end

    local m = {
        leafs = leafs,
        root_hash = root_hash,
        digest_hex = root_hash.digest_hex,
        height = height,
        implicit_hash = implicit_hash,
    }
    setmetatable(m, MerkleTree)
    return m
end

function MerkleTree:join(other_hash)
    return self.root_hash:join(other_hash)
end

function MerkleTree:children()
    return self.root_hash:children()
end

function MerkleTree:iterated_merkle(level)
    return self.root_hash:iterated_merkle(level)
end

function MerkleTree:hex_string()
    return self.root_hash:hex_string()
end

MerkleTree.__eq = function(x, y)
    return x:hex_string() == y:hex_string()
end

MerkleTree.__tostring = function(x)
    return x.root_hash:hex_string()
end


local function generate_proof(proof, root, height, include_index)
    if height == 0 then
        proof.leaf = root
        return
    end

    local new_height = height - 1
    local ok, left, right = root:children()
    assert(ok)

    if ((include_index >> new_height) & 1):iszero() then
        generate_proof(proof, left, new_height, include_index)
        table.insert(proof, right)
    else
        generate_proof(proof, right, new_height, include_index)
        table.insert(proof, left)
    end
end

function MerkleTree:prove_leaf(index)
    assert((index >> self.height):iszero())
    local proof = {}
    generate_proof(proof, self.root_hash, self.height, index)
    return proof.leaf, proof
end

function MerkleTree:last()
    local proof = {}
    local ok, left, right = self.root_hash:children()
    local old_right = self.root_hash

    while ok do
        table.insert(proof, left)
        old_right = right
        ok, left, right = right:children()
    end

    return old_right, arithmetic.array_reverse(proof)
end

function MerkleTree:validate_patch(patch)
    assert(patch.log2size)
    assert(patch.hash)
    assert(patch.position)

    -- first log2size bits must be zero
    local mask = (bint256.one() << patch.log2size) - 1
    assert((mask & patch.position):iszero(), "patch position and log2size not compatible!")
    assert(patch.position < (1 << self.height), "patch position beyond bounds!")

    return patch
end

local function apply_patch(root, height, patch)
    if height == patch.log2size then
        return patch.hash:iterated_merkle(patch.log2size)
    end

    local ok, left, right = root:children()
    assert(ok)

    if patch.position & (1 << (height - 1)) == 0 then
        local new_left = apply_patch(left, height - 1, patch)
        return new_left:join(right)
    else
        local new_right = apply_patch(right, height - 1, patch)
        return left:join(new_right)
    end
end

function MerkleTree:apply_patches(patches)
    local height = self.height
    local new_commitment_root = self.root_hash

    for _, patch in ipairs(patches) do
        self:validate_patch(patch)
        new_commitment_root = apply_patch(new_commitment_root, height, patch)
    end

    return new_commitment_root
end

function MerkleTree:clone_and_patch(patches)
    local root_hash = self:apply_patches(patches)
    local m = {
        original = self,
        patches = patches,

        root_hash = root_hash,
        digest_hex = root_hash.digest_hex,
        height = self.height,
        implicit_hash = self.implicit_hash,
    }
    setmetatable(m, MerkleTree)
    return m
end

return MerkleTree
