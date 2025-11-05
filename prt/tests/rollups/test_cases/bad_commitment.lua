require "setup_path"

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local env = require "test_env"
local time = require "utils.time"


-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there are no inputs for epoch 0

-- Spawn Dave node
env.spawn_node()

-- wait until node has made claim
local _, commitment_node = env.dave_node:root_commitment(0)
time.sleep_until(function()
    return env.reader:commitment_exists(first_epoch.tournament, commitment_node)
end)

print("Node commitment: ", commitment_node)

local bad_commitment_proof = {}
local final_state = Hash.zero

local bad_commitment_left = Hash.zero
local bad_commitment_right = final_state

for _ = 1, 47 do
    bad_commitment_right = Hash.zero:join(bad_commitment_right)
    table.insert(bad_commitment_proof, Hash.zero)
end
table.insert(bad_commitment_proof, bad_commitment_left)

print("Sending bad commitment: ", bad_commitment_left:join(bad_commitment_right))
assert(
    env.sender:tx_join_tournament(
        first_epoch.tournament, final_state, bad_commitment_proof, bad_commitment_left, bad_commitment_right
    )
)
print("Bad commitment sent")

-- Wait for node to win
env.wait_until_epoch(1)

-- validate winners
local _, commitment = Machine.root_rollup_commitment(env.template_machine, 44, {})
local winner = env.reader:root_tournament_winner(first_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == commitment)
assert(winner.commitment == commitment_node)
assert(winner.final == commitment:last())
print("Correct claim won!")
