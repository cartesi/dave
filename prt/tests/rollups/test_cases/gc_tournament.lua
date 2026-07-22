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

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local second_epoch = env.roll_epoch()
assert(second_epoch.epoch_number == 1)
assert(second_epoch.input_upper_bound == 4) -- there are 4 inputs for epoch 1!

local inputs = {}
for _, v in ipairs(env.reader:read_inputs_added(second_epoch.epoch_number)) do
    table.insert(inputs, v.data)
end

-- Compute honest commitment
-- 44 is the initial log2_stride currently configured in the smart contracts.
local initial_state, commitment = Machine.root_rollup_commitment(env.template_machine, 44, inputs)
assert(Hash:from_digest_hex(second_epoch.initial_machine_state_hash) == initial_state,
    "chain-sealed initial machine state hash differs from the computed state")

local honest_commitment_builder = CommitmentBuilder:new(env.template_machine, inputs, commitment)
local patched_commitment_builder1 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 1 << 44 } },
    honest_commitment_builder)
local patched_commitment_builder2 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 2 << 44 } },
    honest_commitment_builder)

local player1 = start_sybil(patched_commitment_builder1, env.template_machine, second_epoch.tournament,
    inputs)
local player2 = start_sybil(patched_commitment_builder2, env.template_machine, second_epoch.tournament,
    inputs)

local delegated_match
env.drive_player_until(player1, function(_, _)
    local _, log2 = env.player_react(player2)
    local root_match = log2.state.matches[1]
    if root_match then
        if root_match.inner_tournament then
            delegated_match = {
                match_id_hash = root_match.match_id_hash,
                commitment_one = root_match.commitment_one,
                commitment_two = root_match.commitment_two,
                child_tournament = root_match.inner_tournament.address,
            }
            return true
        end
    end
    return false
end)
assert(delegated_match, "the root match never delegated to an inner tournament")
assert(delegated_match.commitment_one ~= commitment.root_hash
    and delegated_match.commitment_two ~= commitment.root_hash,
    "the delegated match must contain the two adversarial commitments")

-- Both sybils join the child during the reaction that observes delegation.
-- Capture that exact child match before abandoning them.
local child_commitments = env.reader.inner_reader:read_commitment_joined(
    delegated_match.child_tournament
)
assert(#child_commitments == 2, "expected two adversarial child commitments")

local lazy_child_match
for _, match in ipairs(env.reader.inner_reader:read_match_created(
    delegated_match.child_tournament
)) do
    if has_participants(match, child_commitments[1].root, child_commitments[2].root) then
        assert(not lazy_child_match, "the same child commitments matched more than once")
        lazy_child_match = match
    end
end
assert(lazy_child_match, "the two adversarial child commitments were not paired")

-- Wait for node to garbage collect lazy claims
env.wait_until_epoch(2)

-- GC first eliminates the expired child match, then consumes the eliminable
-- child at the parent. The parent-side CHILD_TOURNAMENT/NONE deletion is the
-- durable proof that the nested cleanup advanced the root tournament.
env.assert_match_deleted(
    delegated_match.child_tournament,
    lazy_child_match,
    "timeout",
    "none"
)
env.assert_match_deleted(
    second_epoch.tournament,
    delegated_match,
    "child_tournament",
    "none"
)

-- validate winners
local winner = env.reader:root_tournament_winner(second_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == commitment)
assert(winner.final == commitment:last())
print("Correct claim won!")
