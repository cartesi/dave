#!/usr/bin/lua
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.path = package.path .. ";./lua_poc/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"

local State = require "player.state"
local HonestStrategy = require "player.honest_strategy"
local GarbageCollectionStrategy = require "player.gc_strategy"
local Sender = require "blockchain.sender"

local time = require "utils.time"
local helper = require "utils.helper"

local player_index = tonumber(arg[1])
local tournament = arg[2]
local machine_path = arg[3]

local state = State:new(tournament)
local sender = Sender:new(player_index)
local honest_strategy
local gc_strategy
do
    local CommitmentBuilder = require "computation.commitment"
    local builder = CommitmentBuilder:new(machine_path)
    honest_strategy = HonestStrategy:new(builder, machine_path, sender)
    gc_strategy = GarbageCollectionStrategy:new(sender)
end

function toJson(item)
    if item~= nil
    then
        local jsonResult = {}
        for key, value in pairs(item) do
            if string.find(tostring(value), "table:") then
                -- skip if the value is table
                goto continue
            end
            table.insert(jsonResult, string.format("\"%s\":%s", key, value))
            ::continue::
        end
        jsonResult = "{" .. table.concat(jsonResult, ",") .. "}"
        stateFile:write(jsonResult)
    end
end

function TM(t)
    if t ~= nil
    then
        -- print("tournament")
        toJson(t)
    
        if t.matches ~= nil
        then
            for i = 1, #t.matches do
                -- print("match")
                toJson(t.matches[i])
                if(t.matches[i] ~= nil and t.matches[i].inner_tournament ~= nil)
                then
                    TM(t.matches[i].inner_tournament)
                end
            end
        end
    end
end

while true do
    state:fetch()

    -- write to a file inside docker
    stateFile = io.open("/app/lua_poc/utils/current-state.json", "w")
    local rt = state.root_tournament
    TM(rt)
    stateFile:close()

    local tx_count = sender.tx_count
    if honest_strategy:react(state) then break end
    -- player is considered idle if no tx sent in current iteration
    if tx_count == sender.tx_count then
        helper.log(player_index, "player idling")
        helper.touch_player_idle(player_index)
    else
        helper.rm_player_idle(player_index)
    end
    gc_strategy:react(state)
    time.sleep(5)
end
