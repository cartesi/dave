#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

-- Required Modules
local State = require "player.state"
local IdleStrategy = require "player.idle_strategy"
local Hash = require "cryptography.hash"
local Sender = require "blockchain.sender"
local time = require "utils.time"
local helper = require "utils.helper"

-- Function to start idle player
local function start_idle_player(player_index, tournament, initial_hash)
    local state = State:new(tournament)
    local sender = Sender:new(player_index)
    local idle_strategy
    do
        local DummyCommitmentBuilder = require "computation.dummy_commitment"
        local builder = DummyCommitmentBuilder:new(initial_hash)
        idle_strategy = IdleStrategy:new(builder, sender)
    end

    while true do
        state:fetch()
        local tx_count = sender.tx_count
        if idle_strategy:react(state) then break end
        -- player is considered idle if no tx sent in current iteration
        if tx_count == sender.tx_count then
            helper.log_timestamp("player idling")
            helper.touch_player_idle(player_index)
        else
            helper.rm_player_idle(player_index)
        end
        time.sleep(5)
    end
end

-- Main Execution
local player_index = tonumber(arg[1])
local tournament = arg[2]
local initial_hash = Hash:from_digest_hex(arg[3])

start_idle_player(player_index, tournament, initial_hash)
