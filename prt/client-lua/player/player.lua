local StateFetcher = require "player.state"
local HonestStrategy = require "player.strategy"
local GarbageCollector = require "player.gc"
local Sender = require "player.sender"
local CommitmentBuilder = require "computation.commitment"
local time = require "utils.time"
local helper = require "utils.helper"


local function new(wallet, tournament_address, machine_path, blokchain_endpoint, hook)
    local sender = Sender:new(wallet.pk, wallet.player_id, blokchain_endpoint)
    local state_fetcher = StateFetcher:new(tournament_address, blokchain_endpoint)
    local gc_strategy = GarbageCollector:new(sender)
    local honest_strategy = HonestStrategy:new(
        CommitmentBuilder:new(machine_path),
        machine_path,
        sender
    )

    local function react()
        local state = state_fetcher:fetch()

        gc_strategy:react(state)
        local log = honest_strategy:react(state)

        if hook then
            hook(state, log)
        end

        return log
    end

    return coroutine.create(function()
        while true do
            local log = react()
            coroutine.yield(log)
        end
    end)
end

return { new = new }
