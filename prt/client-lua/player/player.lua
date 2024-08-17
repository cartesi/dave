local StateFetcher = require "player.state"
local HonestStrategy = require "player.strategy"
local GarbageCollector = require "player.gc"
local Sender = require "player.sender"
local CommitmentBuilder = require "computation.commitment"
local time = require "utils.time"
local helper = require "utils.helper"


local Player = {}
Player.__index = Player

function Player:new(wallet, tournament_address, machine_path, blokchain_endpoint, hook)
    local p = {
        pk = wallet.pk,
        player_id = wallet.player_id,
        tournament_address = tournament_address,
        machine_path = machine_path,
        blokchain_endpoint = blokchain_endpoint,
        hook = hook
    }
    setmetatable(p, self)
    return p
end

function Player:start()
    local state_fetcher = StateFetcher:new(self.tournament_address, self.blokchain_endpoint)
    local sender = Sender:new(self.pk, self.player_id, self.blokchain_endpoint)
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
        if tx_count == sender.tx_count then
            helper.log_timestamp("player idling")
            helper.touch_player_idle(self.player_id)
        else
            helper.rm_player_idle(self.player_id)
        end

        time.sleep(5)
    end
end

return Player
