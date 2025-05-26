require "setup_path"

local Hash = require "cryptography.hash"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"


-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 1) -- there's one input for epoch 0 already!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }


local function run_epoch(sealed_epoch, patches)
    local settlement = env.epoch_settlement(sealed_epoch)

    -- Setup player till completion
    print("Setting up Sybil")
    local player = start_sybil(patches, 1, settlement.machine_path, settlement.commitment, sealed_epoch.tournament,
        settlement.inputs)

    -- Run player till completion
    print("Run Sybil")
    assert(env.drive_player(player) == "lost")

    -- add inputs for next epoch (in case it happens!)
    env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

    -- Wait for node's claim to finally settle
    local next_epoch = env.wait_until_epoch(sealed_epoch.epoch_number + 1)

    -- validate winners
    local winner = env.reader:root_tournament_winner(sealed_epoch.tournament)
    assert(winner.has_winner)
    assert(winner.commitment == settlement.commitment)
    assert(winner.final == settlement.commitment:last())
    print("Correct claim won for epoch ", sealed_epoch.epoch_number)

    return next_epoch
end

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
sealed_epoch = run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})

-- run epoch 2
sealed_epoch = run_epoch(sealed_epoch, {
    -- ustep
    { hash = Hash.zero, meta_cycle = 1 << 44 },
    { hash = Hash.zero, meta_cycle = 1 << 27 },
    { hash = Hash.zero, meta_cycle = 1 << 1 },
})

-- run epoch 3
sealed_epoch = run_epoch(sealed_epoch, {
    -- add input 2 + ustep
    { hash = Hash.zero, meta_cycle = (1 << 48) + (1 << 44) },
    { hash = Hash.zero, meta_cycle = (1 << 48) + (1 << 27) },
    { hash = Hash.zero, meta_cycle = (1 << 48) + (1) },
})
