require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

-- B1 chaos loop (docs/plans/characterization.md): an ordinary dispute
-- epoch, but the node is SIGKILLed and respawned between sybil
-- reactions on a seeded random cadence. Always SIGKILL, never SIGTERM:
-- WAL recovery and half-written state are the subject. Process startup
-- is the downtime - the sybil keeps acting while the node boots. The
-- honest claim must still win the tournament and settle.

local seed = tonumber(os.getenv("CHAOS_SEED")) or os.time()
print(string.format("[chaos] seed = %d (rerun with CHAOS_SEED=%d)", seed, seed))
math.randomseed(seed)

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
local steps_until_kill = math.random(3, 10)
local function chaos_step()
    steps_until_kill = steps_until_kill - 1
    if steps_until_kill <= 0 then
        env.dave_node:kill()
        env.dave_node:respawn()
        kills = kills + 1
        steps_until_kill = math.random(3, 10)
    end
end

-- run epoch 1 under fire; same dispute shape as `simple`
env.run_epoch(sealed_epoch, {
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {}, chaos_step)

print(string.format("[chaos] honest claim settled through %d SIGKILLs", kills))
assert(kills > 0, "the dispute ended before any kill; tighten the cadence")
