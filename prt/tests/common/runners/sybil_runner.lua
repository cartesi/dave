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

local function sybil_runner(commitment_builder, machine_path, root_tournament, inputs, player_id)
    player_id = player_id or 1
    local strategy = HonestStrategy:new(
        commitment_builder,
        inputs,
        machine_path,
        Sender:new(blockchain_consts.pks[player_id], player_id, blockchain_consts.endpoint)
    )
    strategy:disable_gc()

    local react = sybil_player(
        root_tournament,
        strategy,
        blockchain_consts.endpoint
    )

    return react
end

return sybil_runner
