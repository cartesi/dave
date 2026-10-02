require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"


-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there's no input for epoch 0!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
local _, sealed = env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] })

-- With no kills, the eager sybil takes the dispute to its one leaf match,
-- so this smoke also gates that a STEP proof, not a timeout, resolved it.
assert(#sealed == 1, string.format("expected one sealed leaf match, saw %d", #sealed))
env.assert_leaf_match_proved(sealed[1].tournament, sealed[1].match_id_hash)
