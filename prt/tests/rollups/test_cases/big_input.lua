require "setup_path"

local Hash = require "cryptography.hash"
local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"
local start_sybil = require "runners.sybil_runner"
local env = require "test_env"
local conversion = require "utils.conversion"

-- Main Execution
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 1) -- there's one input for epoch 0 already!

local big_input = conversion.bin_from_hex_n("0x6228290203658fd4987e40cbb257cabf258f9c288cdee767eaba6b234a73a2f9")
    :rep((1 << 11) - 10)

assert(big_input:len() == (1 << 16) - 320)
env.sender:tx_add_inputs { conversion.hex_from_bin_n(big_input) }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()
local settlement = env.epoch_settlement(sealed_epoch)
assert(#settlement.inputs == 1)

-- Setup player till completion
print("Setting up Sybil")

-- Makes sure disputes end on the very first state transition, which adds an input!
local patches = {
    { hash = Hash.zero, meta_cycle = 1 << 44 },
    { hash = Hash.zero, meta_cycle = 1 << 27 },
    { hash = Hash.zero, meta_cycle = 1 },
}

local honest_commitment_builder = CommitmentBuilder:new(settlement.machine_path, settlement.inputs,
    settlement.commitment)
local patched_commitment_builder = PatchedCommitmentBuilder:new(patches, honest_commitment_builder)

local player = start_sybil(patched_commitment_builder, settlement.machine_path, sealed_epoch.tournament,
    settlement.inputs)

-- Run player till completion
print("Run Sybil")
assert(env.drive_player(player) == "lost")

-- Wait for node's claim to finally settle
env.wait_until_epoch(2)

-- validate winners
local winner = env.reader:root_tournament_winner(sealed_epoch.tournament)
assert(winner.has_winner)
assert(winner.commitment == settlement.commitment)
assert(winner.final == settlement.commitment:last())
print("Correct claim won!")
