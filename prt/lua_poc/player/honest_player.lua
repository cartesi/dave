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

local flat = require "utils.flat"
local json = require "utils.json"
local bint = require 'utils.bint' (256) -- use 256 bits integers
local constants = require "constants"

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

function output_tournaments(state)
    -- write to a file inside docker
    stateFile = io.open("/app/lua_poc/utils/current-state.json", "w")
    local rt = state.root_tournament
    stateFile:write(json.encode(flat.flatten(state.root_tournament)))
    stateFile:close()
end

function output_hero_claim(state)
    -- output hero claims
    if state.hero_state ~= nil
    then
        hero_state = {}
        claimsFile = io.open("/app/lua_poc/utils/hero-claims.json", "w")
        hero_state.tournament_address = string.format("%s", state.hero_state.tournament.address)
        hero_state.commitment_root_hash = string.format("%s", state.hero_state.commitment.root_hash)
        claimsFile:write(json.encode(hero_state))
        claimsFile:close()
    end
end

function copy_png(one, two)
    local directory = "/app/pixels/"
    local pfile = io.popen('ls -a "'..directory..'"')
    for filename in pfile:lines() do
        local png_name = filename:match("[^/]*.png$")
        if png_name ~= nil
        then
            -- print(png_name)
            local left = tonumber(string.match(png_name, "%d+"))
            local right = tonumber(string.match(png_name, "_%d+"):sub(2))
            -- print(left)
            -- print(right)
            if left <= one and (one < right or right == 0)
            then
                -- found 1
                local cp_command = "cp " .. directory .. png_name .. " " .. directory .. "one.png"
                print(cp_command)
                os.execute(cp_command)
            end
            if left <= two and (two < right or right == 0)
            then
                -- found 2
                local cp_command = "cp " .. directory .. png_name .. " " .. directory .. "two.png"
                print(cp_command)
                os.execute(cp_command)
                pfile:close()
                return
            end
        end
    end
    pfile:close()
end

function pick_2_pngs(state)
    local match = state.hero_state.latest_match
    if match ~= nil and match ~= false and match.current_height ~= 0
    then
        local span = 1 << (match.current_height - 1)
        local agreed_leaf = 0
        if match.running_leaf ~= nil and bint(match.running_leaf) ~= bint(0)
        then
            agreed_leaf = bint(match.running_leaf) - 1
        end
        disagreed_leaf = agreed_leaf + span
        local base = bint(match.tournament.base_big_cycle)
        local step = (bint(1) << match.tournament.log2_stride) >> constants.log2_uarch_span
        local agreed_cycle = base + (step * agreed_leaf)
        local disagreed_cycle = base + (step * disagreed_leaf)
        print("agreed on mcycle " .. tostring(agreed_cycle) .. " disagreed on " .. tostring(disagreed_cycle))
        copy_png(agreed_cycle, disagreed_cycle)
    end
end

while true do
    state:fetch()
    local tx_count = sender.tx_count
    local react = honest_strategy:react(state)

    -- prepare files for frontend
    output_tournaments(state)
    output_hero_claim(state)
    pick_2_pngs(state)

    if react then break end
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
