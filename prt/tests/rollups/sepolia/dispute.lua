require "setup_path"

local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"
local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local start_sybil = require "runners.sybil_runner"
local time = require "utils.time"

local env = require "sepolia.setup_env"

local sealed_epochs = env.reader:read_epochs_sealed()
local sealed_epoch = sealed_epochs[#sealed_epochs]

-- get all inputs
local all_inputs = env.reader:read_inputs_added(sealed_epoch.epoch_number)

-- slice inputs into `sealed_epoch` inputs
local inputs = {}
for i = sealed_epoch.input_lower_bound + 1, sealed_epoch.input_upper_bound do
  table.insert(inputs, all_inputs[i].data)
end

-- Get `sealed_epoch` machine path.

-- Compute honest commitment
-- 44 is the initial log2_stride currently configured in the smart contracts.
local initial_state, commitment = Machine.root_rollup_commitment(env.template_machine, 44, inputs)
assert(sealed_epoch.initial_machine_state_hash, initial_state)

local patches = {
    -- add input 2 + ustep
    { hash = Hash.zero, meta_cycle = (1 << 44) },
    { hash = Hash.zero, meta_cycle = (1 << 27) },
    { hash = Hash.zero, meta_cycle = (1) },
}

local honest_commitment_builder = CommitmentBuilder:new(env.template_machine, inputs, commitment)
local patched_commitment_builder = PatchedCommitmentBuilder:new(patches, honest_commitment_builder)
local player = start_sybil(patched_commitment_builder, env.template_machine, sealed_epoch.tournament, inputs, 1, {pk = env.pk, endpoint = env.gateway})

local function player_react(player_coroutine)
    local success, log = coroutine.resume(player_coroutine)
    assert(success, string.format("player fail to resume with error: %s", log))
    return coroutine.status(player_coroutine), log
end

local function drive_player_until(player_coroutine, condition_f)
    local ret
    while true do
        ret = { condition_f(player_react(player_coroutine)) }

        if ret[1] then
            return table.unpack(ret)
        end

        time.sleep(15)
    end
end

local function drive_player(player_coroutine)
    return drive_player_until(player_coroutine, function(status, log)
        if log.has_lost then
            return "lost"
        elseif status == "dead" then
            return "dead"
        end
    end)
end

-- Run player till completion
print("Run Sybil")
assert(drive_player(player) == "lost")
print "Sybil has lost"
