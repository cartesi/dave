require "setup_path"

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"

local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

-- The audit's multi-match scenario (node-audit.md findings 2, 6, 7):
-- Dave is permissionless, so a tournament can hold several live
-- matches at once - a shape no other net exercises. Four commitments
-- (honest + three sybils) form two concurrent matches; two sybils
-- play actively (one pairing may be sybil-vs-sybil, also untested
-- elsewhere), the third joins and goes silent, so its match resolves
-- through a REAL on-chain timeout - the deletion reason the fold has
-- only ever decoded from synthetic events. With RECORD_CHAIN_FIXTURE
-- set, the whole dispute is captured for the tournament-fold oracle.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local second_epoch = env.roll_epoch()
assert(second_epoch.epoch_number == 1)

local inputs = {}
for _, v in ipairs(env.reader:read_inputs_added(second_epoch.epoch_number)) do
    table.insert(inputs, v.data)
end

-- Compute honest commitment (44 is the contracts' level-0 log2_stride).
local initial_state, commitment = Machine.root_rollup_commitment(env.template_machine, 44, inputs)
assert(second_epoch.initial_machine_state_hash, initial_state)

local honest_builder = CommitmentBuilder:new(env.template_machine, inputs, commitment)
-- Distinct level-0 leaves: the sybils diverge from the honest
-- commitment AND from each other.
local builder1 = PatchedCommitmentBuilder:new(
    { { hash = Hash.zero, meta_cycle = 1 << 44 } }, honest_builder)
local builder2 = PatchedCommitmentBuilder:new(
    { { hash = Hash.zero, meta_cycle = 2 << 44 } }, honest_builder)
local builder3 = PatchedCommitmentBuilder:new(
    { { hash = Hash.zero, meta_cycle = 3 << 44 } }, honest_builder)

-- Each sybil auto-allocates its own signing account (sybil_runner):
-- two of them send concurrently here, which is exactly the case the
-- old shared default wedged on.
local player1 = start_sybil(builder1, env.template_machine, second_epoch.tournament, inputs)
local player2 = start_sybil(builder2, env.template_machine, second_epoch.tournament, inputs)
local player3 = start_sybil(builder3, env.template_machine, second_epoch.tournament, inputs)

-- Everyone joins before anyone fights: driving each sybil until the
-- commitment count rises guarantees four commitments - and therefore
-- two live matches - exist simultaneously. The count includes the
-- honest node's join, so the first threshold also waits for it (the
-- drive loop advances the chain each poll, so the node's finalized
-- view keeps up).
local function commitment_count(log)
    local count = 0
    for _, _ in pairs(log.state.commitments) do
        count = count + 1
    end
    return count
end
local function joined_at_least(n)
    return function(_, log)
        return commitment_count(log) >= n
    end
end
env.drive_player_until(player1, joined_at_least(2))
env.drive_player_until(player2, joined_at_least(3))
env.drive_player_until(player3, joined_at_least(4))

-- Sybil 3 goes silent here: its match must die by timeout. Sybils 1
-- and 2 play on, interleaved (either may be paired with the other,
-- so neither can be driven to completion alone). When both report
-- idle, fast-forward gently (Env.fast_forward: sleep first, small
-- chunks - a dispute is live) so pending clocks, the silent match's
-- above all, actually expire.
local done1, done2 = false, false
local rounds = 0
while not (done1 and done2) do
    rounds = rounds + 1
    assert(rounds < 5000, "multi-sybil dispute did not converge")

    local idle = true
    if not done1 then
        local status, log = env.player_react(player1)
        done1 = status == "dead" or (log and log.has_lost)
        idle = idle and (status == "dead" or (log and log.idle))
    end
    if not done2 then
        local status, log = env.player_react(player2)
        done2 = status == "dead" or (log and log.has_lost)
        idle = idle and (status == "dead" or (log and log.idle))
    end
    if idle then
        env.fast_forward(4)
    end
end
print "both active sybils have lost"

-- The silent sybil's match resolves by timeout (the honest node's
-- win or GC sweep) on the way to settlement.
env.wait_until_epoch(2)

-- validate winners
local winner = env.reader:root_tournament_winner(second_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == commitment)
assert(winner.final == commitment:last())
print "Correct claim won against three sybils!"

-- Raw chain recording for the tournament-fold oracle: the one
-- fixture that carries concurrent matches and a real timeout-reason
-- deletion (see cartesi-rollups/node/tests/tournament_fold.rs).
local fixture = os.getenv "RECORD_CHAIN_FIXTURE"
if fixture then
    local recorder = "../../../target/debug/record_chain"
    local cmd = string.format("%s --out %s --note multi-sybil", recorder, fixture)
    assert(os.execute(cmd), "chain recording failed")
end
