local Blockchain = require "blockchain.node"
local Dave = require "dave.node"
local Machine = require "computation.machine"
local time = require "utils.time"
local Reader = require "dave.reader"
local Sender = require "dave.sender"
local start_sybil = require "runners.sybil_runner"
local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

-- anvil deployment state dump
local ANVIL_PATH = assert(os.getenv("ANVIL_PATH"))

-- machine template hash
local TEMPLATE_MACHINE = assert(os.getenv("TEMPLATE_MACHINE"))

-- addresses
local APP_ADDRESS = assert(os.getenv("APP"))
local CONSENSUS_ADDRESS = assert(os.getenv("CONSENSUS"))
local INPUT_BOX_ADDRESS = assert(os.getenv("INPUT_BOX"))

local SLEEP_TIME = 1
local FAST_FORWARD_TIME = 16

local ECHO_MSG = "0x48656c6c6f2076726f6d204461766521"

local Env = {
    anvil_path = ANVIL_PATH,

    app_address = APP_ADDRESS,
    consensus_address = CONSENSUS_ADDRESS,
    input_box_address = INPUT_BOX_ADDRESS,
    template_machine = TEMPLATE_MACHINE,

    sleep_time = SLEEP_TIME,
    fast_forward_time = FAST_FORWARD_TIME,

    sample_inputs = { ECHO_MSG },

    -- blockchain = false,
    -- reader = false,
    -- sender = false,

    -- dave_node = false,
}

function Env.spawn_blockchain()
    local blockchain = Blockchain:new(ANVIL_PATH)
    Env.blockchain = blockchain
    Env.reader = Reader:new(INPUT_BOX_ADDRESS, CONSENSUS_ADDRESS, blockchain.endpoint)
    Env.sender = Sender:new(INPUT_BOX_ADDRESS, APP_ADDRESS, blockchain.pks[1], blockchain.endpoint)
    Env.sender:advance_blocks(1)
    return blockchain
end

function Env.spawn_node()
    local dave_node = Dave:new(TEMPLATE_MACHINE, APP_ADDRESS, Env.sender, SLEEP_TIME)
    Env.dave_node = dave_node
    return dave_node
end

function Env.roll_epoch()
    assert(Env.blockchain, "blockchain not spawned")
    local epochs = Env.reader:read_epochs_sealed()

    -- wait until node has finished processing epoch
    local _, commitment = Env.dave_node:root_commitment(#epochs - 1)
    time.sleep_until(function()
        return Env.reader:commitment_exists(epochs[#epochs].tournament, commitment)
    end)

    return Env.wait_until_epoch(#epochs)
end

function Env.wait_until_epoch(target_epoch, ff)
    ff = ff or Env.fast_forward_time
    local total_epochs = target_epoch + 1
    local epochs
    time.sleep_until(function()
        epochs = Env.reader:read_epochs_sealed()
        if #epochs >= total_epochs then
            assert(#epochs == total_epochs)
            return true
        else
            Env.sender:advance_blocks(ff)
            return false
        end
    end, 4)
    return assert(epochs[total_epochs])
end

-- returns the machine_path, inputs, initial_state, and commitment
function Env.epoch_settlement(sealed_epoch)
    -- get all inputs
    local all_inputs = Env.reader:read_inputs_added(sealed_epoch.epoch_number)

    -- slice inputs into `sealed_epoch` inputs
    local inputs = {}
    for i = sealed_epoch.input_lower_bound + 1, sealed_epoch.input_upper_bound do
        table.insert(inputs, all_inputs[i].data)
    end

    -- sanity check: read node inputs and assert they are the same
    local node_inputs = Env.dave_node:inputs(sealed_epoch.epoch_number)
    assert(#node_inputs == #inputs)
    for k, v in ipairs(inputs) do
        assert(string.upper(v) == string.upper(node_inputs[k]))
    end

    -- Get `sealed_epoch` machine path.
    local machine_path = assert(Env.dave_node:machine_path(sealed_epoch.epoch_number))

    -- Compute honest commitment
    -- 44 is the initial log2_stride currently configured in the smart contracts.
    local initial_state, commitment = Machine.root_rollup_commitment(machine_path, 44, inputs)
    assert(sealed_epoch.initial_machine_state_hash, initial_state)

    -- sanity check: read node commitment and assert they are the same
    local node_initial_state, node_commitment = Env.dave_node:root_commitment(sealed_epoch.epoch_number)
    assert(initial_state == node_initial_state.root_hash)
    assert(commitment == node_commitment)

    return {
        machine_path = machine_path,
        inputs = inputs,
        initial_state = initial_state,
        commitment = commitment,
    }
end

function Env.player_react(player_coroutine)
    local success, log = coroutine.resume(player_coroutine)
    assert(success, string.format("player fail to resume with error: %s", log))
    return coroutine.status(player_coroutine), log
end

function Env.drive_player_until(player_coroutine, condition_f)
    local ret
    while true do
        ret = { condition_f(Env.player_react(player_coroutine)) }

        if ret[1] then
            return table.unpack(ret)
        end

        time.sleep(Env.sleep_time)
    end
end

function Env.drive_player(player_coroutine)
    return Env.drive_player_until(player_coroutine, function(status, log)
        if log.has_lost then
            return "lost"
        elseif status == "dead" then
            return "dead"
        end
    end)
end

function Env.run_epoch(sealed_epoch, patches)
    local settlement = Env.epoch_settlement(sealed_epoch)

    -- Setup player till completion
    print("Setting up Sybil")


    local honest_commitment_builder = CommitmentBuilder:new(settlement.machine_path, settlement.inputs,
        settlement.commitment)
    local patched_commitment_builder = PatchedCommitmentBuilder:new(patches, honest_commitment_builder)
    local player = start_sybil(patched_commitment_builder, settlement.machine_path, sealed_epoch.tournament,
        settlement.inputs)

    -- Run player till completion
    print("Run Sybil")
    assert(Env.drive_player(player) == "lost")
    print "Sybil has lost"

    -- add inputs for next epoch (in case it happens!)
    Env.sender:tx_add_inputs { Env.sample_inputs[1], Env.sample_inputs[1], Env.sample_inputs[1] }

    -- Wait for node's claim to finally settle
    local next_epoch = Env.wait_until_epoch(sealed_epoch.epoch_number + 1)

    -- validate winners
    local winner = Env.reader:root_tournament_winner(sealed_epoch.tournament)
    assert(winner.has_winner)
    assert(winner.commitment == settlement.commitment)
    assert(winner.final == settlement.commitment:last())
    print("Correct claim won for epoch ", sealed_epoch.epoch_number)

    return next_epoch
end

return Env
