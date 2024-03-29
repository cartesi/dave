#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_node/?.lua"
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
local initial_hash = Hash:from_digest_hex(arg[4])

local state = State:new(tournament)
local sender = Sender:new(player_index)
local honest_strategy
do
    local FakeCommitmentBuilder = require "computation.fake_commitment"
    local builder = FakeCommitmentBuilder:new(initial_hash)
    honest_strategy = HonestStrategy:new(builder, machine_path, sender)
end

while true do
    state:fetch()
    local tx_count = sender.tx_count
    if honest_strategy:react(state) then break end
    -- player is considered idle if no tx sent in current iteration
    if tx_count == sender.tx_count then
        helper.log(player_index, "player idling")
        helper.touch_player_idle(player_index)
    else
        helper.rm_player_idle(player_index)
    end
end
