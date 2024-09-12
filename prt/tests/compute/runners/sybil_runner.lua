#!/usr/bin/lua
require "setup_path"

-- Required Modules
local StateFetcher = require "player.state"
local Sender = require "player.sender"
local HonestStrategy = require "player.strategy"
local helper = require "utils.helper"

-- Function to start dishonest player
local function start_sybil(player, fake_commitment_count)
    local state_fetcher = StateFetcher:new(player.tournament_address, player.blockchain_endpoint)
    local sender = Sender:new(player.pk, player.player_id, player.blockchain_endpoint)
    local honest_strategy
    do
        local FakeCommitmentBuilder = require "runners.helpers.fake_commitment"
        local builder = FakeCommitmentBuilder:new(player.machine_path)
        honest_strategy = HonestStrategy:new(builder, player.machine_path, sender)
    end

    while true do
        local tx_count = sender.tx_count

        -- an sybil runner can send multiple fake commitments
        -- each of them is determined by the `fake_index` of `FakeCommitmentBuilder`
        local finish_count = 0
        for i = 1, fake_commitment_count do
            local state = state_fetcher:fetch()
            helper.log_full(player.player_id, string.format("react with fake index: %d", i))
            honest_strategy.commitment_builder.fake_index = i
            if honest_strategy:react(state).finished then
                finish_count = finish_count + 1
            end
        end

        if finish_count == fake_commitment_count then
            -- all fake commitments are done
            break
        end

        -- player is considered idle if no tx sent in current iteration
        local idle = false
        if tx_count == sender.tx_count then
            idle = true
        end

        coroutine.yield(idle)
    end
end

return start_sybil
