require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

-- Each epoch pins one on-chain state-transition shape by steering the
-- dispute's divergence onto a chosen transition. A patch at meta_cycle
-- M garbles the leaf whose post-state sits at M, i.e. transition M - 1,
-- but it only applies at levels where M is stride-aligned and the
-- descent only follows the EARLIEST divergent leaf of each level; so
-- steering a whole descent takes a chain of three patches: the
-- enclosing level-0 leaf boundary, the enclosing level-1 leaf boundary,
-- and M itself. The alignment and range rules make the chain
-- self-consistent (each boundary patch is also the last leaf of the
-- level below it). Coverage matrix in docs/test-harness.md.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- epoch 1: the closing slot (final ustep + ureset + revert check) of
-- an idle big cycle, reached through idle-churn territory: transition
-- 2^44 - 1, long after input 0 finished. The single boundary patch is
-- a degenerate chain (it is its own boundary at every level).
sealed_epoch = env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 },
}, { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 7)

-- epoch 2: a plain active ustep: transition 2, the third ustep of
-- input 0's first big cycle. The chain steers level 1 to its first
-- leaf and level 2 to position 2, so the seal proves an interior
-- agree leaf.
sealed_epoch = env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 },
    { hash = Hash.zero, meta_cycle = 1 << 28 },
    { hash = Hash.zero, meta_cycle = 3 },
}, { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 10)

-- epoch 3: an idle churn ustep: transition 2^48 is the first slot of
-- an idle big cycle (the interpreter noticing the machine is yielded).
-- Divergence at level-2 position 0 also exercises the seal whose agree
-- state is the level's initial hash.
sealed_epoch = env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = (1 << 48) + (1 << 44) },
    { hash = Hash.zero, meta_cycle = (1 << 48) + (1 << 28) },
    { hash = Hash.zero, meta_cycle = (1 << 48) + 1 },
}, { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 13)

-- epoch 4: the fused feed of input 1 (checkpoint write + input
-- delivery + first ustep): transition 2^68, the first dispute past
-- window 0. Replays cross a fed input boundary and the transition
-- proof carries the data-availability and checkpoint-write material.
env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = (1 << 68) + (1 << 44) },
    { hash = Hash.zero, meta_cycle = (1 << 68) + (1 << 28) },
    { hash = Hash.zero, meta_cycle = (1 << 68) + 1 },
})
