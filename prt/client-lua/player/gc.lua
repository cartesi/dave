local helper = require "utils.helper"

local GarbageCollector = {}
GarbageCollector.__index = GarbageCollector

function GarbageCollector:new(sender)
    local gc_strategy = {
        sender = sender
    }

    setmetatable(gc_strategy, self)
    return gc_strategy
end

function GarbageCollector:_react_match(match)
    helper.log_full(self.sender.index,
        string.format("Garbage collect match at HEIGHT: %d, of tournament: %s", match.current_height,
            match.tournament.address))
    if match.inner_tournament then
        return self:_react_tournament(match.inner_tournament)
    end
end

function GarbageCollector:_react_tournament(tournament)
    for _, match in ipairs(tournament.matches) do
        if match then
            local status_1 = tournament.commitments[match.commitment_one].status
            local status_2 = tournament.commitments[match.commitment_two].status

            self:_react_match(match)

            -- try to eliminate matches that both clocks are out of time
            if (not status_1.clock:has_time() and
                    (status_1.clock:time_since_timeout() > status_2.clock.allowance)) or
                (not status_2.clock:has_time() and
                    (status_2.clock:time_since_timeout() > status_1.clock.allowance)) then
                helper.log_full(self.sender.index, string.format(
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
                    helper.log_full(self.sender.index, string.format(
                        "eliminate match reverted: %s",
                        e
                    ))
                end
            end
        end
    end
end

function GarbageCollector:react(root_tournament)
    return self:_react_tournament(root_tournament)
end

return GarbageCollector
