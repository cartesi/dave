require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

-- SIGKILL the node right after it advances a match, keep it down while
-- the sybil plays on (ten sybil reactions of downtime, the honest clock
-- ticking), then respawn. The dispute must still be won and settle.

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
local function kill_after_advance()
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
    matched, offset = env.dave_node:find_log("advance match", offset)
    if matched then
        env.dave_node:kill()
        kills = kills + 1
        down_for = DOWNTIME_STEPS
    end
end

-- same dispute shape as `simple`, with the node dead mid-bisection
env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {}, kill_after_advance)

assert(kills == 1, "the dispute never reached an advance")
assert(down_for == 0, "the node never came back up")
print "[kill_mid_match] dispute won despite mid-bisection downtime"
