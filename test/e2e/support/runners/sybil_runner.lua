-- Required Modules
local blockchain_consts = require "blockchain.constants"
local Actor = require "player.actor"
local SemanticReader = require "player.semantic_reader"
local Sender = require "player.sender"

local function sybil_player(actor)
    local function react()
        return actor:react()
    end

    return coroutine.create(function()
        local log
        repeat
            log = react()
            coroutine.yield(log)
        until log.finished
    end)
end

-- Sybils sign with their own accounts, auto-allocated from 2 up:
-- account 1 is the honest node's, and the old shared default wedged
-- on nonces the moment two sybils sent concurrently (found building
-- multi_sybil; every serial scenario had silently gotten away with
-- it). Pass player_id or config.pk to override deliberately - but
-- never the node's own account.
local next_player_id = 2

local function sybil_runner(commitment_builder, machine_path, root_tournament, inputs, player_id, config)
    config = config or {}
    if not player_id then
        player_id = next_player_id
        next_player_id = next_player_id + 1
    end
    assert(
        config.pk or player_id ~= 1,
        "player_id 1 is the honest node's account; sybils sign with their own"
    )
    assert(blockchain_consts.pks[player_id], "no test account for player_id " .. player_id)
    local pk = config.pk or blockchain_consts.pks[player_id]
    local endpoint = config.endpoint or blockchain_consts.endpoint
    local sender =
        config.sender or Sender:new(pk, player_id, endpoint)
    local reader = config.reader or SemanticReader.from_endpoint(
        root_tournament,
        config.creation_block or 0,
        endpoint
    )
    local actor = Actor.new {
        reader = reader,
        commitment_builder = commitment_builder,
        machine_path = machine_path,
        inputs = inputs,
        sender = sender,
        root_initial_hash = config.root_initial_hash,
        gc_enabled = config.gc_enabled == true,
        machine_logs = config.machine_logs,
        -- Patched sybils deliberately claim a wrong post-state. They still
        -- submit the locally valid proof so the contract rejects the move and
        -- the adversarial clock path remains exercised.
        allow_invalid_claims = config.allow_invalid_claims ~= false,
    }
    if config.gc_enabled == false then
        actor:disable_gc()
    end
    return sybil_player(actor)
end

return sybil_runner
