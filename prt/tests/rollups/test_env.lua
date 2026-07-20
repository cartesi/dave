local Blockchain = require "blockchain.node"
local Dave = require "dave.node"
local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local time = require "utils.time"
local Reader = require "dave.reader"
local Sender = require "dave.sender"
local start_sybil = require "runners.sybil_runner"
local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local CommitmentBuilder = require "computation.commitment"

-- anvil deployment state dump; the dump is opt-in (see the justfile:
-- its flag pair makes anvil retain all historical states in memory)
local ANVIL_LOAD_PATH = assert(os.getenv("ANVIL_LOAD_PATH"))
local ANVIL_DUMP_PATH = os.getenv("ANVIL_DUMP_PATH")
if ANVIL_DUMP_PATH == "" then ANVIL_DUMP_PATH = nil end

-- machine template hash
local TEMPLATE_MACHINE = assert(os.getenv("TEMPLATE_MACHINE"))
local TEMPLATE_MACHINE_HASH = assert(os.getenv("TEMPLATE_MACHINE_HASH"))

-- addresses
local DAVE_APP_FACTORY_ADDRESS = assert(os.getenv("DAVE_APP_FACTORY"))
local INPUT_BOX_ADDRESS = assert(os.getenv("INPUT_BOX"))

-- create2 salt value
local SALT = "0x" .. string.rep("00", 32)

local SLEEP_TIME = 1
-- Blocks advanced per wait_until_epoch poll (4s cadence). Timeout
-- waits dominate the timeout-heavy scenarios' wall clock (suite
-- economics, docs/test-harness.md): clock allowances are ~300 blocks
-- and eliminations need ~300 more past expiry, so 16 meant minutes of
-- throttled ticking per expiry. 128 keeps a few polls of granularity
-- per allowance; overshooting an expiry is harmless (elimination
-- WANTS overshoot). Env-overridable for tuning.
local FAST_FORWARD_TIME = tonumber(os.getenv("FAST_FORWARD_TIME")) or 128

-- TEST_INSTANCE isolates parallel runs (see blockchain.constants);
-- the oracle lineage is a working-directory singleton like the rest.
local ORACLE_DIR = "_oracle" .. (os.getenv("TEST_INSTANCE") and ("-" .. os.getenv("TEST_INSTANCE")) or "")

local ECHO_MSG = "0x48656c6c6f2076726f6d204461766521"

local Env = {
    anvil_load_path = ANVIL_LOAD_PATH,
    anvil_dump_path = ANVIL_DUMP_PATH,

    input_box_address = INPUT_BOX_ADDRESS,
    dave_app_factory_address = DAVE_APP_FACTORY_ADDRESS,
    template_machine = TEMPLATE_MACHINE,
    template_machine_hash = TEMPLATE_MACHINE_HASH,

    sleep_time = SLEEP_TIME,
    fast_forward_time = FAST_FORWARD_TIME,

    sample_inputs = { ECHO_MSG },

    -- blockchain = false,
    -- reader = false,
    -- sender = false,

    -- dave_node = false,
    -- app_address = false,
    -- consensus_address = false,
}

function Env.spawn_blockchain(inputs)
    inputs = inputs or {}

    -- The machine wrapper's revert-snapshot scratch: clear at scenario
    -- start so stale or torn stores never carry across runs (the
    -- hash-named dirs are content-addressed, but a killed run can
    -- leave a partial store the exists() gate would adopt).
    os.execute("rm -rf " .. Machine.default_snapshot_scratch)

    local blockchain = Blockchain:new(ANVIL_LOAD_PATH, ANVIL_DUMP_PATH)
    Env.blockchain = blockchain
    Env.sentries = { Dave.wallet_address }
    Env.reader = Reader:new(INPUT_BOX_ADDRESS, DAVE_APP_FACTORY_ADDRESS, TEMPLATE_MACHINE_HASH, Env.sentries, SALT,
        blockchain.endpoint)
    Env.app_address = Env.reader.app_address
    Env.consensus_address = Env.reader.consensus_address
    Env.sender = Sender:new(INPUT_BOX_ADDRESS, DAVE_APP_FACTORY_ADDRESS, Env.app_address, blockchain.pks[1],
        blockchain.endpoint)
    Env.sender:tx_new_dave_app(TEMPLATE_MACHINE_HASH, Env.sentries, SALT)
    Env.sender:tx_add_inputs(inputs)
    Env.sender:advance_blocks(2)
    return blockchain
end

function Env.spawn_node(snapshot_gap)
    local dave_node = Dave:new(TEMPLATE_MACHINE, Env.app_address, Env.sender, SLEEP_TIME,
        snapshot_gap)
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

-- The oracle: an independent machine lineage anchored at the template.
-- It replays only chain inputs, epoch after epoch, so node output is
-- never an input to the oracle, only a subject of comparison.
local function oracle_get()
    if not Env.oracle then
        os.execute(string.format("rm -rf %s && mkdir -p %s/snapshots", ORACLE_DIR, ORACLE_DIR))
        local machine = Machine:new_from_path(TEMPLATE_MACHINE, ORACLE_DIR .. "/snapshots")
        Env.oracle = { machine = machine, epoch = 0 }
    end
    return Env.oracle
end

-- Chain inputs of a sealed epoch, straight from InputAdded events.
local function chain_inputs(sealed_epoch)
    local all_inputs = Env.reader:read_inputs_added(sealed_epoch.epoch_number)
    local inputs = {}
    for i = sealed_epoch.input_lower_bound + 1, sealed_epoch.input_upper_bound do
        table.insert(inputs, all_inputs[i].data)
    end
    return inputs
end

-- Advance the oracle through one sealed epoch, verifying the chain
-- anchor (EpochSealed's initial state) before moving. Returns the
-- epoch's initial state and commitment.
local function oracle_advance(sealed_epoch, inputs)
    local oracle = oracle_get()
    assert(oracle.epoch == sealed_epoch.epoch_number, "oracle advances in epoch order")

    local initial_state = oracle.machine:state().root_hash
    assert(Hash:from_digest_hex(sealed_epoch.initial_machine_state_hash) == initial_state,
        "chain-sealed initial machine state hash differs from the oracle lineage")

    -- Keep the epoch-start snapshot: sybils build their commitments
    -- from it, so even adversaries stop depending on node internals.
    local snapshot_path = ORACLE_DIR .. "/epoch-" .. sealed_epoch.epoch_number
    oracle.machine:store_to(snapshot_path)

    -- 44 is the initial log2_stride currently configured in the smart contracts.
    local _, commitment, processing_bigs = oracle.machine:rollup_commitment(44, inputs)
    oracle.epoch = oracle.epoch + 1

    return initial_state, commitment, snapshot_path, processing_bigs
end

-- returns the machine_path, inputs, initial_state, and commitment
function Env.epoch_settlement(sealed_epoch)
    local oracle = oracle_get()

    -- Catch up on epochs the scenario did not settle through us.
    while oracle.epoch < sealed_epoch.epoch_number do
        local past = assert(Env.reader:read_epochs_sealed()[oracle.epoch + 1],
            "missing sealed epoch for oracle catch-up")
        oracle_advance(past, chain_inputs(past))
    end

    local inputs = chain_inputs(sealed_epoch)

    -- Cross-check: node inputs against chain inputs.
    local node_inputs = Env.dave_node:inputs(sealed_epoch.epoch_number)
    assert(#node_inputs == #inputs)
    for k, v in ipairs(inputs) do
        assert(string.upper(v) == string.upper(node_inputs[k]))
    end

    local initial_state, commitment, machine_path, processing_bigs = oracle_advance(sealed_epoch, inputs)

    -- Cross-checks: the node's snapshot and commitment against the
    -- oracle. The node is the subject here, never the source.
    local node_machine_path = assert(Env.dave_node:machine_path(sealed_epoch.epoch_number))
    local node_snapshot_state = Machine:new_from_path(node_machine_path):state().root_hash
    assert(node_snapshot_state == initial_state,
        "node epoch snapshot differs from the oracle lineage")

    local node_initial_state, node_commitment = Env.dave_node:root_commitment(sealed_epoch.epoch_number)
    assert(initial_state == node_initial_state.root_hash)
    assert(commitment == node_commitment,
        "node commitment differs from the oracle commitment")

    return {
        machine_path = machine_path,
        inputs = inputs,
        initial_state = initial_state,
        commitment = commitment,
        -- big cycles each input consumed, from the oracle lineage;
        -- lets scenarios aim patch chains at revert closing slots
        processing_bigs = processing_bigs,
    }
end

function Env.player_react(player_coroutine)
    local success, log = coroutine.resume(player_coroutine)
    assert(success, string.format("player fail to resume with error: %s", log))
    return coroutine.status(player_coroutine), log
end

-- `on_step` (optional) runs between sybil reactions; chaos scenarios
-- use it to kill and respawn the node mid-dispute.
function Env.drive_player_until(player_coroutine, condition_f, on_step)
    local ret
    while true do
        ret = { condition_f(Env.player_react(player_coroutine)) }

        if ret[1] then
            return table.unpack(ret)
        end

        if on_step then
            on_step()
        end
        -- One block per poll, unconditionally: the node ingests
        -- FINALIZED blocks, so a quiet chain freezes its view and
        -- deadlocks any wait-for-the-node loop (the finality-freeze
        -- class, node-audit.md). One block per second is the natural
        -- cadence - it cannot starve the node's turn the way bulk
        -- fast-forwards can (see Env.fast_forward).
        Env.sender:advance_blocks(1)
        time.sleep(Env.sleep_time)
    end
end

-- The clock-safe fast-forward for scenario code: sleep FIRST, so the
-- node's pending move (it ticks every second) lands before the jump,
-- then advance. Bulk advances between the node's ticks burn its
-- block-denominated chess clock while it is on turn - observed as an
-- honest node timing out of its own dispute at 128 blocks per idle
-- poll. Callers fast-forwarding while a dispute is LIVE must keep
-- `blocks` small (multi_sybil uses 4); big jumps are safe only when
-- no match awaits the node's move (wait_until_epoch's settlement
-- polling).
function Env.fast_forward(blocks)
    time.sleep(1)
    Env.sender:advance_blocks(blocks)
end

function Env.drive_player(player_coroutine, on_step)
    return Env.drive_player_until(player_coroutine, function(status, log)
        if log.has_lost then
            return "lost"
        elseif status == "dead" then
            return "dead"
        end
    end, on_step)
end

-- `patches` is a list, or a function of the settlement (for patch
-- positions only the oracle can compute, like revert slots).
function Env.run_epoch(sealed_epoch, patches, next_inputs, on_step)
    next_inputs = next_inputs or {}
    local settlement = Env.epoch_settlement(sealed_epoch)
    if type(patches) == "function" then
        patches = patches(settlement)
    end

    -- Setup player till completion
    print("Setting up Sybil")

    local honest_commitment_builder = CommitmentBuilder:new(settlement.machine_path, settlement.inputs,
        settlement.commitment)
    local patched_commitment_builder = PatchedCommitmentBuilder:new(patches, honest_commitment_builder)
    local player = start_sybil(patched_commitment_builder, settlement.machine_path, sealed_epoch.tournament,
        settlement.inputs)

    -- Run player till completion
    print("Run Sybil")
    assert(Env.drive_player(player, on_step) == "lost")
    print "Sybil has lost"

    -- add inputs for next epoch (in case it happens!)
    Env.sender:tx_add_inputs(next_inputs)

    -- Wait for node's claim to finally settle
    local next_epoch = Env.wait_until_epoch(sealed_epoch.epoch_number + 1)

    -- validate winners
    local winner = Env.reader:root_tournament_winner(sealed_epoch.tournament)
    assert(winner.has_winner)
    assert(winner.commitment == settlement.commitment)
    assert(winner.final == settlement.commitment:last())
    print("Correct claim won for epoch ", sealed_epoch.epoch_number)

    -- Raw chain recording for the tournament-fold oracle
    -- (docs/plans/node-refactor.md, workstream 2a). Recorded after
    -- settlement so the fixture carries the whole dispute; when a
    -- scenario settles several epochs, the last recording wins the
    -- file and contains all of them.
    local fixture = os.getenv "RECORD_CHAIN_FIXTURE"
    if fixture then
        local recorder = "../../../target/debug/record_chain"
        local cmd = string.format("%s --out %s --note epoch-%d",
            recorder, fixture, sealed_epoch.epoch_number)
        assert(os.execute(cmd), "chain recording failed")
    end

    return next_epoch
end

return Env
