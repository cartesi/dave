-- Required Modules
local blockchain_consts = require "blockchain.constants"
local DummyCommitment = require "runners.helpers.dummy_commitment"
local IdleStrategy = require "runners.helpers.idle_strategy"
local Sender = require "player.sender"
local Player = require "player.player"

local function idle_runner(player_id, machine_path, root_tournament)
    local strategy = IdleStrategy:new(
        DummyCommitment:new(machine_path),
        Sender:new(blockchain_consts.pks[player_id], player_id, blockchain_consts.endpoint)
    )
    local react = Player.new(
        root_tournament,
        strategy,
        blockchain_consts.endpoint,
        false
    )

    return react
end

return idle_runner
