-- Required Modules
local blockchain_consts = require "blockchain.constants"
local HonestStrategy = require "player.strategy"
local Sender = require "player.sender"
local StateFetcher = require "player.state"

local function sybil_player(root_tournament, strategy, blockchain_endpoint)
    local state_fetcher = StateFetcher:new(root_tournament, blockchain_endpoint)

    local function react()
        local state = state_fetcher:fetch()
        local log = strategy:react(state)
        return { idle = log.idle, finished = log.finished, has_lost = log.has_lost, state = state }
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

    local strategy = HonestStrategy:new(
        commitment_builder,
        inputs,
        machine_path,
        Sender:new(pk, player_id, endpoint)
    )
    strategy:disable_gc()

    local react = sybil_player(
        root_tournament,
        strategy,
        endpoint
    )

    return react
end

return sybil_runner
