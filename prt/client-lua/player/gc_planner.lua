local Domain = require "player.domain"

-- Pure, actor-neutral cleanup policy over one accepted dispute observation.
--
-- The returned list is complete and deterministic. Execution takes only a
-- bounded prefix after Hero policy selects no arena action.
local GcPlanner = {}

local function observation_for(observations, tournament)
    local observation = observations[tournament]
    assert(observation,
        "reachable tournament is missing its semantic observation")
    return observation
end

local function append(planned, sequence, depth, intent)
    table.insert(planned, {
        depth = depth,
        sequence = sequence,
        intent = intent,
    })
    return sequence + 1
end

local function plan_tournament(
    fold,
    observations,
    tournament_address,
    planned,
    sequence
)
    local tournament = assert(fold:tournament(tournament_address),
        "reachable tournament is missing from the fold")
    local observation = observation_for(observations, tournament_address)

    for _, match in ipairs(fold:live_matches(tournament_address)) do
        local observed = observation.matches[match.id_hash]
        assert(observed,
            "live folded match is missing its semantic observation")
        assert(Domain.same_match_id(observed.id, match.id),
            "fold and observer disagree on ordered match identity")

        local state = observed.live.state
        if state._tag == Domain.LiveMatchState.AWAITING_CHILD then
            local child_address = state.child_tournament
            local child_fold = assert(fold:tournament(child_address),
                "awaiting-child match names an undiscovered tournament")
            local child = observation_for(observations, child_address)
            if child.standing._tag ==
                Domain.TournamentStanding.INNER_ELIMINABLE
            then
                sequence = append(
                    planned,
                    sequence,
                    child_fold.level,
                    Domain.eliminate_child_intent(
                        tournament_address,
                        child_address
                    )
                )
            else
                sequence = plan_tournament(
                    fold,
                    observations,
                    child_address,
                    planned,
                    sequence
                )
            end
        end

        if observed.live.timeout._tag ==
            Domain.TimeoutDisposition.ELIMINATE_BOTH
        then
            sequence = append(
                planned,
                sequence,
                tournament.level,
                Domain.eliminate_match_intent(
                    tournament_address,
                    observed.id
                )
            )
        end
    end

    return sequence
end

function GcPlanner.plan(fold, observations)
    assert(type(fold) == "table", "GC planner requires a structural fold")
    assert(type(observations) == "table",
        "GC planner requires semantic observations")
    local planned = {}
    plan_tournament(
        fold,
        observations,
        fold:root(),
        planned,
        1
    )

    table.sort(planned, function(left, right)
        if left.depth ~= right.depth then
            return left.depth > right.depth
        end
        return left.sequence < right.sequence
    end)

    local intents = {}
    for _, entry in ipairs(planned) do
        table.insert(intents, entry.intent)
    end
    return intents
end

return GcPlanner
