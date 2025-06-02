require "setup_path"

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"

local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 1) -- there's one input for epoch 0 already!


local inputs = {}
for _, v in ipairs(env.reader:read_inputs_added(first_epoch.epoch_number)) do
    table.insert(inputs, v.data)
end

-- Compute honest commitment
-- 44 is the initial log2_stride currently configured in the smart contracts.
local initial_state, commitment = Machine.root_rollup_commitment(env.template_machine, 44, inputs)
assert(first_epoch.initial_machine_state_hash, initial_state)

local honest_commitment_builder = CommitmentBuilder:new(env.template_machine, inputs, commitment)
local patched_commitment_builder1 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 1 << 44 } },
    honest_commitment_builder)
local patched_commitment_builder2 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 2 << 44 } },
    honest_commitment_builder)

local player1 = start_sybil(patched_commitment_builder1, env.template_machine, first_epoch.tournament,
    inputs)
local player2 = start_sybil(patched_commitment_builder2, env.template_machine, first_epoch.tournament,
    inputs)

env.drive_player_until(player1, function(_, log)
    local count = 0
    for _, _ in pairs(log.state.commitments) do
        count = count + 1
    end
    return count > 0
end)
env.drive_player_until(player2, function(_, log)
    local count = 0
    for _, _ in pairs(log.state.commitments) do
        count = count + 1
    end
    return count > 1
end)


-- Spawn Dave node
env.spawn_node()

-- Wait for node to garbage collect lazy claims
env.wait_until_epoch(1)

-- validate winners
local winner = env.reader:root_tournament_winner(first_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == commitment)
assert(winner.final == commitment:last())
print("Correct claim won!")
