local Domain = require "player.domain"

-- Pure actor policy over one validated semantic snapshot.
--
-- Planning performs no RPC, machine, proof, or sender work. The first
-- applicable category wins and one root observation yields one decision.
local Planner = {}

local function plan_hero(snapshot)
    local standing = snapshot.standing
    local standing_tag = standing._tag

    if standing_tag == Domain.TournamentStanding.ROOT_WINNER then
        if standing.commitment == snapshot.local_commitment then
            return Domain.terminal(Domain.HeroTerminal.WON)
        end
        return Domain.terminal(Domain.HeroTerminal.LOST)
    end

    if standing_tag == Domain.TournamentStanding.ROOT_FAILED then
        return Domain.terminal(Domain.HeroTerminal.FAILED_NO_WINNER)
    end

    if standing_tag == Domain.TournamentStanding.INNER_WINNER then
        local parent = assert(snapshot.parent,
            "validated inner snapshot is missing its parent")
        if standing.parent_commitment ~= parent.parent_commitment then
            return Domain.terminal(Domain.HeroTerminal.LOST)
        end
        return Domain.act(Domain.propagation_intent {
            parent_tournament = parent.parent_tournament,
            child_tournament = snapshot.descriptor.address,
            parent_match = parent.parent_match,
            parent_commitment = parent.parent_commitment,
            parent_side = parent.parent_side,
            child_winner = standing.child_commitment,
        })
    end

    if standing_tag == Domain.TournamentStanding.INNER_ELIMINABLE then
        return Domain.wait(Domain.WaitReason.CHILD_ELIMINABLE, {
            elimination_reason = standing.reason,
            candidate = standing.candidate,
        })
    end

    local local_standing = snapshot.local_standing
    local local_tag = local_standing._tag
    if local_tag == Domain.LocalCommitmentStanding.NOT_JOINED then
        if Domain.standing_accepts_joins(standing) then
            return Domain.act(Domain.join_intent(
                snapshot.descriptor.address,
                snapshot.local_commitment
            ))
        end
        return Domain.wait(Domain.WaitReason.JOINS_CLOSED)
    end

    if local_tag == Domain.LocalCommitmentStanding.CANDIDATE then
        if standing_tag == Domain.TournamentStanding.MATCHES_ACTIVE then
            return Domain.wait(
                Domain.WaitReason.CANDIDATE_BLOCKED_BY_MATCHES
            )
        end
        assert(standing_tag == Domain.TournamentStanding.AWAITING_CLOSURE,
            "candidate reached an impossible nonterminal standing")
        return Domain.wait(Domain.WaitReason.AWAITING_TOURNAMENT_CLOSURE)
    end

    if local_tag == Domain.LocalCommitmentStanding.ELIMINATED then
        return Domain.terminal(Domain.HeroTerminal.LOST)
    end

    assert(local_tag == Domain.LocalCommitmentStanding.ENGAGED,
        "unknown local commitment standing")
    local engagement = local_standing.engagement
    local timeout = engagement.live.timeout
    local winner, deferred_charge = Domain.timeout_winner(timeout)
    if winner then
        if winner ~= engagement.local_side then
            return Domain.wait(
                Domain.WaitReason.OPPONENT_WINS_BY_TIMEOUT,
                { winner = winner }
            )
        end
        return Domain.act(Domain.timeout_intent {
            tournament = snapshot.descriptor.address,
            match_id = engagement.match_id,
            commitment = snapshot.local_commitment,
            survivor = winner,
            deferred_charge = deferred_charge,
        })
    end

    if timeout._tag == Domain.TimeoutDisposition.ELIMINATE_BOTH then
        return Domain.wait(Domain.WaitReason.MATCH_ELIMINABLE)
    end

    assert(timeout._tag == Domain.TimeoutDisposition.NONE,
        "unknown timeout disposition")
    local state = engagement.live.state
    local state_tag = state._tag
    local side = engagement.local_side
    local locator = {
        tournament = snapshot.descriptor.address,
        match_id = engagement.match_id,
        commitment = snapshot.local_commitment,
        side = side,
        match_state = state,
    }

    if state_tag == Domain.LiveMatchState.BISECTING then
        if state.responder ~= side then
            return Domain.wait(Domain.WaitReason.OPPONENT_TURN, {
                responder = state.responder,
            })
        end
        return Domain.act(Domain.advance_intent(locator))
    end

    if state_tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF then
        if state.responder ~= side then
            return Domain.wait(Domain.WaitReason.OPPONENT_TURN, {
                responder = state.responder,
            })
        end
        return Domain.act(Domain.seal_intent(locator))
    end

    if state_tag == Domain.LiveMatchState.READY_TO_DELEGATE then
        if state.responder ~= side then
            return Domain.wait(Domain.WaitReason.OPPONENT_TURN, {
                responder = state.responder,
            })
        end
        return Domain.act(Domain.child_intent(locator))
    end

    if state_tag == Domain.LiveMatchState.SEALED_LEAF then
        return Domain.act(Domain.proof_intent(locator))
    end

    assert(state_tag == Domain.LiveMatchState.AWAITING_CHILD,
        "unknown live match state")
    return plan_hero(assert(snapshot.child,
        "validated awaiting-child snapshot is missing its child"))
end

function Planner.plan(snapshot)
    assert(type(snapshot) == "table"
        and snapshot._tag == "semantic_snapshot",
        "planner requires a semantic snapshot")
    return plan_hero(snapshot)
end

return Planner
