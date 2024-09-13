local StateFetcher = require "player.state"

local function new(tournament_address, strategy, blokchain_endpoint, hook)
    local state_fetcher = StateFetcher:new(tournament_address, blokchain_endpoint)

    local function react()
        local state = state_fetcher:fetch()
        local log = strategy:react(state)

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
