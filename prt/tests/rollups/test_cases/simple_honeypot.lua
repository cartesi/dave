require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

local honeypot_withdrawal_address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
local withdrawal_input = { sender = honeypot_withdrawal_address, payload = "0x" }

-- Main Execution
env.spawn_blockchain { withdrawal_input }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 1) -- there's one input for epoch 0 already!

-- Add 3 inputs to epoch 1
-- env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})
