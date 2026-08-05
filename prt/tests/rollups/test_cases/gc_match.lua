require "setup_path"

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"

local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

local function has_participants(match, one, two)
    return (match.commitment_one == one and match.commitment_two == two)
        or (match.commitment_one == two and match.commitment_two == one)
end

-- Main Execution
env.spawn_blockchain {env.sample_inputs[1]}
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there's no input for epoch 0!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Build the adversarial setup before the node exists: the sybils must join
-- moments after epoch 1 seals, while the node's own commitment build starts
-- from zero, so the two adversarial commitments deterministically pair with
-- each other rather than with the honest claim.
local inputs = {}
for _, v in ipairs(env.reader:read_inputs_added(1)) do
    table.insert(inputs, v.data)
end

-- Compute honest commitment
-- 44 is the initial log2_stride currently configured in the smart contracts.
local initial_state, commitment = Machine.root_rollup_commitment(env.template_machine, 44, inputs)

local honest_commitment_builder = CommitmentBuilder:new(env.template_machine, inputs, commitment)
local patched_commitment_builder1 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 1 << 44 } },
    honest_commitment_builder)
local patched_commitment_builder2 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 2 << 44 } },
    honest_commitment_builder)

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local second_epoch = env.roll_epoch()
assert(second_epoch.epoch_number == 1)
assert(second_epoch.input_upper_bound == 4) -- there are 4 inputs for epoch 1!
assert(Hash:from_digest_hex(second_epoch.initial_machine_state_hash) == initial_state,
    "chain-sealed initial machine state hash differs from the computed state")

local player1 = start_sybil(patched_commitment_builder1, env.template_machine, second_epoch.tournament,
    inputs)
local player2 = start_sybil(patched_commitment_builder2, env.template_machine, second_epoch.tournament,
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

-- Pin the setup before waiting: the two adversarial commitments, not the
-- honest node, must be the lazy match that GC later eliminates.
local adversarial_commitments = {}
for _, joined in ipairs(env.reader.inner_reader:read_commitment_joined(second_epoch.tournament)) do
    if joined.root ~= commitment.root_hash then
        table.insert(adversarial_commitments, joined.root)
    end
end
assert(#adversarial_commitments == 2, "expected exactly two adversarial root commitments")

local lazy_match
for _, match in ipairs(env.reader.inner_reader:read_match_created(second_epoch.tournament)) do
    if has_participants(match, adversarial_commitments[1], adversarial_commitments[2]) then
        assert(not lazy_match, "the same adversarial pair matched more than once")
        lazy_match = match
    end
end
assert(lazy_match, "the two adversarial commitments were not paired")

-- Wait for node to garbage collect lazy claims
env.wait_until_epoch(2)

-- Both lazy commitments expired. This is the exact root-match GC result;
-- an eventual honest winner alone would not distinguish it from another
-- timeout or dispute path.
env.assert_match_deleted(second_epoch.tournament, lazy_match, "timeout", "none")

-- validate winners
local winner = env.reader:root_tournament_winner(second_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == commitment)
assert(winner.final == commitment:last())
print("Correct claim won!")
