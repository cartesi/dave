local StateFetcher = require "player.state"

local function new(tournament_address, strategy, blockchain_endpoint, hook)
    local state_fetcher = StateFetcher:new(tournament_address, blockchain_endpoint)

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
