-- Required Modules
local blockchain_consts = require "blockchain.constants"
local FakeCommitmentBuilder = require "runners.helpers.fake_commitment"
local HonestStrategy = require "player.strategy"
local Sender = require "player.sender"
local helper = require "utils.helper"
local StateFetcher = require "player.state"

local function sybil_player(root_tournament, strategy, blockchain_endpoint, fake_commitment_count)
    local state_fetcher = StateFetcher:new(root_tournament, blockchain_endpoint)

    local function react()
        local idle = true
        local finished = true
        for i = 1, fake_commitment_count do
            local state = state_fetcher:fetch()
            strategy.commitment_builder.fake_index = i
            helper.log_timestamp(string.format("react with fake index: %d", i))

            local log = strategy:react(state)
            strategy.commitment_builder.fake_index = false
            idle = idle and log.idle
            finished = finished and log.finished
        end

        return { idle = idle, finished = finished }
    end

    return coroutine.create(function()
        local log
        repeat
            log = react()
            coroutine.yield(log)
        until log.finished
    end)
end


local function sybil_runner(player_id, machine_path, root_commitment, root_tournament, fake_commitment_count, inputs)
    local snapshot_dir = string.format("/compute_data/%s", root_tournament)
    local strategy = HonestStrategy:new(
        FakeCommitmentBuilder:new(machine_path, root_commitment, snapshot_dir),
        inputs,
        machine_path,
        Sender:new(blockchain_consts.pks[player_id], player_id, blockchain_consts.endpoint)
    )
    strategy:disable_gc()

    local react = sybil_player(
        root_tournament,
        strategy,
        blockchain_consts.endpoint,
        fake_commitment_count
    )

    return react
end

return sybil_runner
