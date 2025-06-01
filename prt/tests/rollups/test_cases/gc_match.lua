require "setup_path"

local Hash = require "cryptography.hash"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"
local conversion = require "utils.conversion"

local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 1) -- there's one input for epoch 0 already!


local settlement = env.epoch_settlement(first_epoch)

local honest_commitment_builder = CommitmentBuilder:new(settlement.machine_path, settlement.inputs,
    settlement.commitment)
local patched_commitment_builder1 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 1 } },
    honest_commitment_builder)
local patched_commitment_builder2 = PatchedCommitmentBuilder:new({ { hash = Hash.zero, meta_cycle = 2 } }, honest_commitment_builder)

local player1 = start_sybil(patched_commitment_builder1, settlement.machine_path, first_epoch.tournament,
    settlement.inputs)
local player2 = start_sybil(patched_commitment_builder2, settlement.machine_path, first_epoch.tournament,
    settlement.inputs)

env.drive_player_until(player1, function(_, log) return #log.state.commitments == 1 end)
env.drive_player_until(player2, function(_, log) return #log.state.commitments == 2 end)
--
-- local big_input = conversion.bin_from_hex_n("0x6228290203658fd4987e40cbb257cabf258f9c288cdee767eaba6b234a73a2f9")
--     :rep(1 << 12)
--
-- assert(big_input:len() == 1 << 17)
-- env.sender:tx_add_inputs { conversion.hex_from_bin_n(big_input) }
--
-- -- Spawn Dave node
-- env.spawn_node()
--
-- -- advance such that epoch 0 is finished
-- local sealed_epoch = env.roll_epoch()
-- local settlement = env.epoch_settlement(sealed_epoch)
-- assert(#settlement.inputs == 1)
--
-- -- Setup player till completion
-- print("Setting up Sybil")
--
-- -- Makes sure disputes end on the very first state transition, which adds an input!
-- local patches = {
--     { hash = Hash.zero, meta_cycle = 1 << 44 },
--     { hash = Hash.zero, meta_cycle = 1 << 27 },
--     { hash = Hash.zero, meta_cycle = 1 },
-- }
-- local player = start_sybil(patches, 1, settlement.machine_path, settlement.commitment, sealed_epoch.tournament,
--     settlement.inputs)
--
-- -- Run player till completion
-- print("Run Sybil")
-- assert(env.drive_player(player) == "lost")
--
-- -- Wait for node's claim to finally settle
-- env.wait_until_epoch(3)
--
-- -- validate winners
-- local winner = env.reader:root_tournament_winner(sealed_epoch.tournament)
-- assert(winner.has_winner)
-- assert(winner.commitment == settlement.commitment)
-- assert(winner.final == settlement.commitment:last())
-- print("Correct claim won!")
