local Domain = require "player.domain"
local bint = require "utils.bint" (256)

-- Pure, actor-neutral cleanup policy over event-authoritative match schedules
-- and the accepted standing of each discovered child tournament.
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
    current_block,
    tournament_address,
    planned,
    sequence
)
    local tournament = assert(fold:tournament(tournament_address),
        "reachable tournament is missing from the fold")

    for _, match in ipairs(fold:live_matches(tournament_address)) do
        if match.inner_tournament then
            local child_address = match.inner_tournament
            local child_fold = assert(fold:tournament(child_address),
                "inner match names an undiscovered tournament")
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
                    current_block,
                    child_address,
                    planned,
                    sequence
                )
            end
        else
            assert(match.eliminable_at,
                "live match is missing its elimination schedule")
        end

        if match.eliminable_at and
            bint.ule(match.eliminable_at, current_block)
        then
            sequence = append(
                planned,
                sequence,
                tournament.level,
                Domain.eliminate_match_intent(
                    tournament_address,
                    match.id
                )
            )
        end
    end

    return sequence
end

function GcPlanner.plan(fold, observations, current_block)
    assert(type(fold) == "table", "GC planner requires a structural fold")
    assert(type(observations) == "table",
        "GC planner requires semantic observations")
    assert(type(current_block) == "number"
        and math.type(current_block) == "integer"
        and current_block >= 0,
        "GC planner requires a nonnegative current block")
    local planned = {}
    plan_tournament(
        fold,
        observations,
        bint(current_block),
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
