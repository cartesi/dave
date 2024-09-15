#!/usr/bin/lua
require "setup_path"

-- Required Modules
local blockchain_consts = require "blockchain.constants"
local CommitmentBuilder = require "computation.commitment"
local HonestStrategy = require "player.strategy"
local Sender = require "player.sender"
local Player = require "player.player"

local function hero_runner(player_id, machine_path, tournament_address, extra_data)
    local hook

    if extra_data then
        print("extra data is enabled")
        hook = require "doom_showcase.hook"
    else
        hook = false
    end

    local strategy = HonestStrategy:new(
        CommitmentBuilder:new(machine_path),
        machine_path,
        Sender:new(blockchain_consts.pks[player_id], player_id, blockchain_consts.endpoint)
    )
    local react = Player.new(
        tournament_address,
        strategy,
        blockchain_consts.endpoint,
        hook
    )

    return react
end

return hero_runner
