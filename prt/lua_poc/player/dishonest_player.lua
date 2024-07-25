#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

local State = require "player.state"
local Hash = require "cryptography.hash"
local Sender = require "blockchain.sender"
local HonestStrategy = require "player.honest_strategy"

local time = require "utils.time"
local helper = require "utils.helper"

local player_index = tonumber(arg[1])
local tournament = arg[2]
local machine_path = arg[3]
local fake_count = tonumber(arg[4]) or 1

local state = State:new(tournament)
local sender = Sender:new(player_index)
local honest_strategy
do
    local FakeCommitmentBuilder = require "computation.fake_commitment"
    local builder = FakeCommitmentBuilder:new(machine_path)
    honest_strategy = HonestStrategy:new(builder, machine_path, sender)
end

while true do
    local tx_count = sender.tx_count

    -- an dishonest player can send multiple fake commitments
    -- each of them is determined by the `fake_index` of `FakeCommitmentBuilder`
    local finish_count = 0
    for i = 1, fake_count do
        time.sleep(5)
        state:fetch()

        helper.log_timestamp(string.format("react with fake index: %d", i))
        honest_strategy.commitment_builder.fake_index = i
        if honest_strategy:react(state) then
            finish_count = finish_count + 1
        end
    end

    if finish_count == fake_count then
        -- all fake commitments are done
        break
    end

    -- player is considered idle if no tx sent in current iteration
    if tx_count == sender.tx_count then
        helper.log_timestamp("player idling")
        helper.touch_player_idle(player_index)
    else
        helper.rm_player_idle(player_index)
    end
end
