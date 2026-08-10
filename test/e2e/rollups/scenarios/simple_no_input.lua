require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"


-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there are no inputs for epoch 0

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
sealed_epoch = env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})
assert(sealed_epoch.input_upper_bound == 0)

-- run epoch 2
env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})
assert(sealed_epoch.input_upper_bound == 0)
