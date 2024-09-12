local StateFetcher = require "player.state"
local HonestStrategy = require "player.strategy"
local GarbageCollector = require "player.gc"
local Sender = require "player.sender"
local CommitmentBuilder = require "computation.commitment"
local time = require "utils.time"
local helper = require "utils.helper"


local Player = {}
Player.__index = Player

function Player:new(wallet, tournament_address, machine_path, blockchain_endpoint, hook)
    local p = {
        pk = wallet.pk,
        player_id = wallet.player_id,
        tournament_address = tournament_address,
        machine_path = machine_path,
        blockchain_endpoint = blockchain_endpoint,
        hook = hook
    }
    setmetatable(p, self)
    return p
end

function Player:start()
    local state_fetcher = StateFetcher:new(self.tournament_address, self.blockchain_endpoint)
    local sender = Sender:new(self.pk, self.player_id, self.blockchain_endpoint)
    local gc_strategy = GarbageCollector:new(sender)
    local honest_strategy = HonestStrategy:new(
        CommitmentBuilder:new(self.machine_path),
        self.machine_path,
        sender
    )

    while true do
        local state = state_fetcher:fetch()
        gc_strategy:react(state)

        local tx_count = sender.tx_count
        local log = honest_strategy:react(state)

        if self.hook then
            self.hook(state, log)
        end

        if log.finished then break end

        -- player is considered idle if no tx sent in current iteration
        local idle = false
        if tx_count == sender.tx_count then
            idle = true
        end

        coroutine.yield(idle)
    end
end

return Player
