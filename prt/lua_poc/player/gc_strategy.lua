local helper = require "utils.helper"

local GarbageCollectionStrategy = {}
GarbageCollectionStrategy.__index = GarbageCollectionStrategy

function GarbageCollectionStrategy:new(sender)
    local gc_strategy = {
        sender = sender
    }

    setmetatable(gc_strategy, self)
    return gc_strategy
end

function GarbageCollectionStrategy:_react_match(state, match)
    helper.log_timestamp("Garbage collect match at HEIGHT: " .. match.current_height)
    if match.inner_tournament then
        return self:_react_tournament(state, match.inner_tournament)
    end
end

function GarbageCollectionStrategy:_react_tournament(state, tournament)
    helper.log_timestamp("Garbage collect tournament at address: " .. tournament.address)

    for _, match in ipairs(tournament.matches) do
        if match then
            local status_1 = tournament.commitments[match.commitment_one].status
            local status_2 = tournament.commitments[match.commitment_two].status

            self:_react_match(state, match)

            -- try to eliminate matches that both clocks are out of time
            if (not status_1.clock:has_time() and
                    (status_1.clock:time_since_timeout() > status_2.clock.allowance)) or
                (not status_2.clock:has_time() and
                    (status_2.clock:time_since_timeout() > status_1.clock.allowance)) then
                helper.log_timestamp(string.format(
                    "eliminate match for commitment %s and %s at tournament %s of level %d",
                    match.commitment_one,
                    match.commitment_two,
                    tournament.address,
                    tournament.level
                ))

                local ok, e = self.sender:eliminate_match(
                    tournament.address,
                    match.commitment_one,
                    match.commitment_two
                )
                if not ok then
                    helper.log_timestamp(string.format(
                        "eliminate match reverted: %s",
                        e
                    ))
                end
            end
        end
    end
end

function GarbageCollectionStrategy:react(state)
    return self:_react_tournament(state, state.root_tournament)
end

return GarbageCollectionStrategy
