#!/usr/bin/lua
require "setup_path"

-- Required Modules
local StateFetcher = require "player.state"
local Sender = require "player.sender"
local HonestStrategy = require "player.strategy"
local time = require "utils.time"
local helper = require "utils.helper"

-- Function to start dishonest player
local function start_dishonest_player(wallet, tournament, machine_path, endpoint, fake_commitment_count)
    local state_fetcher = StateFetcher:new(tournament, endpoint)
    local sender = Sender:new(wallet.pk, wallet.player_id, endpoint)
    local honest_strategy
    do
        local FakeCommitmentBuilder = require "runners.helpers.fake_commitment"
        local builder = FakeCommitmentBuilder:new(machine_path)
        honest_strategy = HonestStrategy:new(builder, machine_path, sender)
    end

    while true do
        local tx_count = sender.tx_count

        -- an dishonest player can send multiple fake commitments
        -- each of them is determined by the `fake_index` of `FakeCommitmentBuilder`
        local finish_count = 0
        for i = 1, fake_commitment_count do
            local state = state_fetcher:fetch()
            helper.log_timestamp(string.format("react with fake index: %d", i))
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
local fake_commitment_count = tonumber(arg[4])

local blockchain_consts = require "blockchain.constants"
start_dishonest_player(
    { pk = blockchain_consts.pks[player_index], player_id = player_index },
    tournament,
    machine_path,
    blockchain_consts.endpoint,
    fake_commitment_count
)
