local StateFetcher = require "player.state"
local HonestStrategy = require "player.strategy"
local CommitmentBuilder = require "computation.commitment"
local Sender = require "player.sender"

local function new(tournament_address, wallet, machine_path, blokchain_endpoint, hook)
    local state_fetcher = StateFetcher:new(tournament_address, blokchain_endpoint)
    local strategy = HonestStrategy:new(
        CommitmentBuilder:new(machine_path),
        machine_path,
        Sender:new(wallet.pk, wallet.player_id, blokchain_endpoint)
    )

    local function react()
        local state = state_fetcher:fetch()
        local log = strategy:react(state)

        if hook then
            hook(state, log)
        end

        return log
    end

    return coroutine.create(function()
        local log
        repeat
            log = react()
            coroutine.yield(log)
        until log.finished
    end)
end

return { new = new }
