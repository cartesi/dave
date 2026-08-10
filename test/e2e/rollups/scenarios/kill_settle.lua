require "setup_path"

local env = require "test_env"
local time = require "utils.time"

-- SIGKILL the node the moment it announces a settle transaction,
-- respawn, and require settlement to complete exactly once - whether
-- the transaction escaped before the kill (the respawned node must
-- tolerate the already-settled epoch) or not (it must retry). No
-- sybil needed.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node, and kill it as it goes to settle its first epoch.
-- Settlement needs chain time, so the wait must mine blocks itself
-- (nothing else transacts at this point); settlement sits behind a
-- couple hundred blocks of tournament closing time, so mine in
-- strides or this wait dominates the whole scenario.
env.spawn_node()
local offset = 0
time.sleep_until(function()
    env.sender:advance_blocks(20)
    local matched
    matched, offset = env.dave_node:find_log("settle epoch", offset)
    return matched ~= nil
end)
env.dave_node:kill()
env.dave_node:respawn()

-- The epoch must still roll and the next one settle identically to
-- the oracle: exactly-once settlement plus post-restart liveness.
local sealed_epoch = env.roll_epoch()
env.epoch_settlement(sealed_epoch)
print "[kill_settle] settlement survived a SIGKILL at the settle transaction"
