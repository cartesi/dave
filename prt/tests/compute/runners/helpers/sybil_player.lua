local StateFetcher = require "player.state"
local Sender = require "player.sender"
local HonestStrategy = require "player.strategy"
local helper = require "utils.helper"

local function new(wallet, tournament_address, machine_path, blokchain_endpoint, fake_commitment_count)
    local state_fetcher = StateFetcher:new(tournament_address, blokchain_endpoint)
    local sender = Sender:new(wallet.pk, wallet.player_id, blokchain_endpoint)


    local FakeCommitmentBuilder = require "runners.helpers.fake_commitment"
    local builder = FakeCommitmentBuilder:new(machine_path)
    local strategy = HonestStrategy:new(builder, machine_path, sender)
    strategy:disable_gc()

    local function react()
        local idle = true
        local finished = true

        -- an dishonest player can send multiple fake commitments
        -- each of them is determined by the `fake_index` of `FakeCommitmentBuilder`
        for i = 1, fake_commitment_count do
            local state = state_fetcher:fetch()
            helper.log_timestamp(string.format("react with fake index: %d", i))
            strategy.commitment_builder.fake_index = i

            local log = strategy:react(state)
            idle = idle and log.idle
            finished = finished and log.finished
        end

        return { idle = idle, finished = finished }
    end

    return coroutine.create(function()
        while true do
            local log = react()
            coroutine.yield(log)
        end
    end)
end

return new
