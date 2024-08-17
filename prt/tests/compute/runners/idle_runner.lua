#!/usr/bin/lua
require "setup_path"

-- Required Modules
local StateFetcher = require "player.state"
local IdleStrategy = require "runners.helpers.idle_strategy"
local Sender = require "player.sender"
local time = require "utils.time"
local helper = require "utils.helper"

-- Function to start idle player
local function start_idle_player(wallet, tournament, machine_path, endpoint)
    local state_fetcher = StateFetcher:new(tournament, endpoint)
    local sender = Sender:new(wallet.pk, wallet.player_id, endpoint)
    local idle_strategy
    do
        local DummyCommitmentBuilder = require "runners.helpers.dummy_commitment"
        local builder = DummyCommitmentBuilder:new(machine_path)
        idle_strategy = IdleStrategy:new(builder, sender)
    end

    while true do
        local state = state_fetcher:fetch()
        local tx_count = sender.tx_count
        if idle_strategy:react(state) then break end
        -- player is considered idle if no tx sent in current iteration
        if tx_count == sender.tx_count then
            helper.log_timestamp("player idling")
            helper.touch_player_idle(wallet.player_id)
        else
            helper.rm_player_idle(wallet.player_id)
        end
        time.sleep(5)
    end
end

-- Main Execution
local player_index = tonumber(arg[1])
local tournament = arg[2]
local machine_path = arg[3]

local blockchain_consts = require "blockchain.constants"

start_idle_player(
    {
        pk = blockchain_consts.pks[player_index],
        player_id = player_index
    },
    tournament,
    blockchain_consts.endpoint,
    machine_path
)
