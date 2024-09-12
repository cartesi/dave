#!/usr/bin/lua
require "setup_path"

-- Required Modules
local StateFetcher = require "player.state"
local IdleStrategy = require "runners.helpers.idle_strategy"
local Sender = require "player.sender"
local time = require "utils.time"
local helper = require "utils.helper"

-- Function to start idle player
local function start_idle_player(player)
    local state_fetcher = StateFetcher:new(player.tournament_address, player.blockchain_endpoint)
    local sender = Sender:new(player.pk, player.player_id, player.blockchain_endpoint)
    local idle_strategy
    do
        local DummyCommitmentBuilder = require "runners.helpers.dummy_commitment"
        local builder = DummyCommitmentBuilder:new(player.machine_path)
        idle_strategy = IdleStrategy:new(builder, sender)
    end

    while true do
        local state = state_fetcher:fetch()
        local tx_count = sender.tx_count
        if idle_strategy:react(state) then break end

        -- player is considered idle if no tx sent in current iteration
        local idle = false
        if tx_count == sender.tx_count then
            idle = true
        end

        coroutine.yield(idle)
    end
end

return start_idle_player
