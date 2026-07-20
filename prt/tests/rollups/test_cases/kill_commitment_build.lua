require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

-- B3 commitment-build kill (docs/plans/characterization.md): during a
-- dispute, SIGKILL the node the moment it starts dispute-time machine
-- work ("computing quartet", the sling compute marker; level 0 is
-- seed-served, so the first occurrence is an inner level's build) and
-- respawn immediately. The quartet cache must resume the half-built
-- level and the dispute must still be won.

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

local kills = 0
local offset = 0
local function kill_on_compute()
    if kills > 0 then
        return
    end
    local matched
    matched, offset = env.dave_node:find_log("computing quartet", offset)
    if matched then
        env.dave_node:kill()
        env.dave_node:respawn()
        kills = kills + 1
    end
end

-- same dispute shape as `simple`, under the build-time kill
env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {}, kill_on_compute)

assert(kills == 1, "the dispute never reached a quartet computation")
print "[kill_commitment_build] dispute won across a mid-build SIGKILL"
