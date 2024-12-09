-- Required Modules
local blockchain_consts = require "blockchain.constants"
local CommitmentBuilder = require "computation.commitment"
local HonestStrategy = require "player.strategy"
local Sender = require "player.sender"
local Player = require "player.player"

local function hero_runner(player_id, machine_path, root_commitment, root_tournament, extra_data, inputs)
    local hook

    if extra_data then
        print("extra data is enabled")
        hook = require "doom_showcase.hook"
    else
        hook = false
    end

    local snapshot_dir = string.format("/compute_data/%s", root_tournament)
    local strategy = HonestStrategy:new(
        CommitmentBuilder:new(machine_path, snapshot_dir, root_commitment),
        inputs,
        machine_path,
        Sender:new(blockchain_consts.pks[player_id], player_id, blockchain_consts.endpoint)
    )
    local react = Player.new(
        root_tournament,
        strategy,
        blockchain_consts.endpoint,
        hook
    )

    return react
end

return hero_runner
