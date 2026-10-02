require "setup_path"

local env = require "test_env"
local uint256 = require "utils.bint" (256)

-- Each epoch pins one on-chain state-transition shape: the dispute is
-- steered onto a chosen transition (env.steering_patches builds the patch
-- chain from the deployed level table) and run_steered_epoch asserts the
-- leaf match sealed exactly there and a STEP proof resolved it. Coverage
-- matrix in docs/test-harness.md.

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

-- epoch 1: the closing slot (final ustep + ureset) of an idle big
-- cycle, reached through idle-churn territory, long after input 0
-- finished.
sealed_epoch = env.run_steered_epoch(sealed_epoch, (1 << 44) - 1,
    { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 7)

-- epoch 2: a plain active ustep, the third of input 0's first big cycle.
sealed_epoch = env.run_steered_epoch(sealed_epoch, 2,
    { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 10)

-- epoch 3: an idle churn ustep: the first slot of an idle big cycle (the
-- interpreter noticing the machine is yielded). It is the first leaf of
-- its leaf tournament, so the seal's agree state is the level's initial
-- hash.
sealed_epoch = env.run_steered_epoch(sealed_epoch, 1 << 48,
    { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })
assert(sealed_epoch.input_upper_bound == 13)

-- epoch 4: the fused feed of input 1 (input delivery with its revert
-- root + first ustep), the first dispute past window 0. Replays cross a
-- fed input boundary and the transition proof carries the
-- data-availability and send-CMIO log material. 2^68 exceeds a Lua
-- integer, so the position is a bint.
env.run_steered_epoch(sealed_epoch, uint256.one() << 68)
