require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

-- The join-point kill (node-audit.md finding 7): SIGKILL the node
-- right as it decides to join the tournament - the one lifecycle
-- moment no other kill scenario covers. The join transaction may or
-- may not have landed when the kill hits; the respawned node must
-- re-derive its claim from storage and end up joined exactly once
-- (a landed join absorbs, a lost one is resubmitted), then win the
-- dispute as usual.

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

local DOWNTIME_STEPS = 10
local kills = 0
local down_for = 0
local offset = 0
local function kill_at_join()
    if down_for > 0 then
        down_for = down_for - 1
        if down_for == 0 then
            env.dave_node:respawn()
        end
        return
    end
    if kills > 0 then
        return
    end
    local matched
    matched, offset = env.dave_node:find_log("join tournament", offset)
    if matched then
        env.dave_node:kill()
        kills = kills + 1
        down_for = DOWNTIME_STEPS
    end
end

-- same dispute shape as `simple`, with the node dead at its join
env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {}, kill_at_join)

assert(kills == 1, "the node never reached its join")
assert(down_for == 0, "the node never came back up")
print "[kill_join] dispute won despite a kill at the join point"
