local bint = require "utils.bint" (256)
local Domain = require "player.domain"
local Machine = require "computation.machine"

-- Local fulfillment of one pure Hero intent.
--
-- This module may inspect cached commitment trees and derive machine proofs,
-- but it performs no provider reads and sends no transaction.
local Fulfiller = {}

Fulfiller.PreparedAction = {
    JOIN = "join",
    CLAIM_TIMEOUT = "claim_timeout",
    ADVANCE = "advance",
    SEAL_LEAF = "seal_leaf",
    CREATE_CHILD = "create_child",
    PROVE_LEAF = "prove_leaf",
    PROPAGATE_CHILD = "propagate_child",
}

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function same(left, right)
    return left == right
end

local function same_uint(left, right)
    return bint.eq(bint(left), bint(right))
end

local function prepared(tag, fields)
    fields._tag = tag
    return fields
end

local function proof_root(leaf, siblings, position)
    local root = leaf
    position = bint(position)
    for height, sibling in ipairs(siblings) do
        local bit = (position >> (height - 1)) & bint.one()
        if bint.iszero(bit) then
            root = root:join(sibling)
        else
            root = sibling:join(root)
        end
    end
    return root
end

local function root_children(level, action)
    local found, left, right = level.commitment:children()
    assert(found, action .. " local commitment has no root opening")
    assert(left:join(right) == level.commitment.root_hash,
        action .. " local root opening is inconsistent")
    return left, right
end

local function local_level(context, tournament, commitment, action)
    local snapshot = assert(
        context:snapshot_at(tournament),
        action .. " tournament is absent from the local semantic path"
    )
    local level = assert(
        context:level(tournament),
        action .. " tournament has no retained commitment material"
    )
    assert(snapshot.descriptor.address == level.descriptor.address
        and snapshot.descriptor.level == level.descriptor.level
        and snapshot.descriptor.height == level.descriptor.height,
        action .. " semantic descriptor disagrees with local material")
    assert(same(snapshot.local_commitment, commitment)
        and same(level.commitment.root_hash, commitment),
        action .. " intent commitment disagrees with local material")
    return snapshot, level
end

local function same_coordinate(left, right)
    return same_uint(left.leaf_position, right.leaf_position)
        and same_uint(left.cycle, right.cycle)
end

local function same_waiting(left, right)
    return same(left.left, right.left) and same(left.right, right.right)
end

local function same_divergence(left, right)
    return same(left.agree_state, right.agree_state)
        and same_coordinate(left.coordinate, right.coordinate)
        and same(left.final_state_one, right.final_state_one)
        and same(left.final_state_two, right.final_state_two)
end

local function same_state(left, right)
    if left._tag ~= right._tag then
        return false
    end
    if left._tag == Domain.LiveMatchState.BISECTING
        or left._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
        or left._tag == Domain.LiveMatchState.READY_TO_DELEGATE
    then
        return same(left.revealing_parent, right.revealing_parent)
            and same_waiting(left.waiting_children, right.waiting_children)
            and same_coordinate(left.coordinate, right.coordinate)
            and left.remaining_height == right.remaining_height
            and left.responder == right.responder
    end
    if left._tag == Domain.LiveMatchState.SEALED_LEAF then
        return same_divergence(left.divergence, right.divergence)
    end
    assert(left._tag == Domain.LiveMatchState.AWAITING_CHILD,
        "unknown live match state")
    return same_divergence(left.divergence, right.divergence)
        and left.child_tournament == right.child_tournament
end

local function engagement(
    context,
    tournament,
    match_id,
    commitment,
    side,
    state,
    action
)
    local snapshot, level =
        local_level(context, tournament, commitment, action)
    local local_standing = snapshot.local_standing
    assert(local_standing._tag == Domain.LocalCommitmentStanding.ENGAGED,
        action .. " intent does not match a local engagement")
    local current = local_standing.engagement
    assert(Domain.same_match_id(current.match_id, match_id),
        action .. " intent carries the wrong match")
    assert(current.local_side == side,
        action .. " intent carries the wrong local side")
    assert(same(
        Domain.side_commitment(side, match_id),
        commitment
    ), action .. " intent side does not own its commitment")
    if state then
        assert(same_state(current.live.state, state),
            action .. " intent state disagrees with accepted snapshot")
    end
    return current, level, snapshot
end

local function node_at(level, subtree_height, position, action)
    local descriptor = level.descriptor
    assert(type(subtree_height) == "number"
        and math.type(subtree_height) == "integer"
        and subtree_height >= 0
        and subtree_height <= descriptor.height,
        action .. " subtree height is outside local commitment")
    position = bint(position)
    local alignment = bint.one() << subtree_height
    assert(bint.iszero(position % alignment),
        action .. " subtree position is misaligned")
    assert(bint.ult(position, bint.one() << descriptor.height),
        action .. " subtree position is outside local commitment")

    local node = level.commitment.root_hash
    local height = descriptor.height
    while height > subtree_height do
        local found, left, right = node:children()
        assert(found, action .. " local commitment path is unavailable")
        height = height - 1
        local bit = (position >> height) & bint.one()
        node = bint.iszero(bit) and left or right
    end
    return node
end

local function unresolved_opening(level, state, action)
    local parent = node_at(
        level,
        state.remaining_height,
        state.coordinate.leaf_position,
        action
    )
    assert(same(parent, state.revealing_parent),
        action .. " local node disagrees with revealing parent")
    local found, left, right = parent:children()
    assert(found, action .. " revealing parent has no local opening")
    assert(left:join(right) == parent,
        action .. " revealing-parent opening is inconsistent")
    return left, right
end

local function prepare_join(intent, context)
    local action = "join"
    local snapshot, level = local_level(
        context,
        intent.tournament,
        intent.commitment,
        action
    )
    assert(snapshot.local_standing._tag
        == Domain.LocalCommitmentStanding.NOT_JOINED
        and Domain.standing_accepts_joins(snapshot.standing),
        "join intent no longer matches the accepted snapshot")

    local left, right = root_children(level, action)
    local final_state, proof = level.commitment:last()
    local last_position =
        (bint.one() << level.descriptor.height) - bint.one()
    assert(proof_root(final_state, proof, last_position)
        == level.commitment.root_hash,
        "join last-leaf proof does not open local commitment")
    return prepared(Fulfiller.PreparedAction.JOIN, {
        tournament = intent.tournament,
        final_state = final_state,
        proof = proof,
        left = left,
        right = right,
    })
end

local function prepare_timeout(intent, context)
    local action = "claim timeout"
    local current, level = engagement(
        context,
        intent.tournament,
        intent.match_id,
        intent.commitment,
        intent.survivor,
        nil,
        action
    )
    local winner, charge = Domain.timeout_winner(current.live.timeout)
    assert(winner == intent.survivor
        and charge ~= nil
        and same_uint(charge, intent.deferred_charge),
        "timeout intent disagrees with accepted timeout disposition")
    local left, right = root_children(level, action)
    return prepared(Fulfiller.PreparedAction.CLAIM_TIMEOUT, {
        tournament = intent.tournament,
        match_id = intent.match_id,
        left = left,
        right = right,
    })
end

local function prepare_advance(intent, context)
    local action = "advance"
    local current, level = engagement(
        context,
        intent.tournament,
        intent.match_id,
        intent.commitment,
        intent.side,
        intent.match_state,
        action
    )
    assert(current.live.timeout._tag == Domain.TimeoutDisposition.NONE
        and intent.match_state._tag == Domain.LiveMatchState.BISECTING
        and intent.match_state.responder == intent.side,
        "advance intent no longer matches the accepted snapshot")

    local left, right =
        unresolved_opening(level, intent.match_state, action)
    local waiting = intent.match_state.waiting_children
    local selected
    if left ~= waiting.left then
        selected = left
    elseif right ~= waiting.right then
        selected = right
    else
        error("advance found no divergent branch", 2)
    end
    local found, new_left, new_right = selected:children()
    assert(found, "advance selected branch has no local opening")
    assert(new_left:join(new_right) == selected,
        "advance selected-branch opening is inconsistent")
    return prepared(Fulfiller.PreparedAction.ADVANCE, {
        tournament = intent.tournament,
        match_id = intent.match_id,
        left = left,
        right = right,
        new_left = new_left,
        new_right = new_right,
    })
end

local function prepare_seal(intent, context, create_child)
    local action = create_child and "create child" or "seal leaf"
    local current, level = engagement(
        context,
        intent.tournament,
        intent.match_id,
        intent.commitment,
        intent.side,
        intent.match_state,
        action
    )
    local expected_tag = create_child
        and Domain.LiveMatchState.READY_TO_DELEGATE
        or Domain.LiveMatchState.READY_TO_SEAL_LEAF
    assert(current.live.timeout._tag == Domain.TimeoutDisposition.NONE
        and intent.match_state._tag == expected_tag
        and intent.match_state.responder == intent.side,
        action .. " intent no longer matches the accepted snapshot")

    local left, right =
        unresolved_opening(level, intent.match_state, action)
    local waiting = intent.match_state.waiting_children
    local position = bint(intent.match_state.coordinate.leaf_position)
    local left_diverges = left ~= waiting.left
    if not left_diverges then
        assert(right ~= waiting.right,
            action .. " found no divergent branch")
        position = position + bint.one()
    end

    local agree_state
    local proof
    if bint.iszero(position) then
        agree_state = level.descriptor.initial_hash
        proof = {}
    else
        agree_state, proof =
            level.commitment:prove_leaf(position - bint.one())
        assert(proof_root(agree_state, proof, position - bint.one())
            == level.commitment.root_hash,
            action .. " agree-state proof does not open local commitment")
        if not left_diverges then
            assert(agree_state == left,
                action .. " right divergence has the wrong agree state")
        end
    end

    return prepared(
        create_child
            and Fulfiller.PreparedAction.CREATE_CHILD
            or Fulfiller.PreparedAction.SEAL_LEAF,
        {
            tournament = intent.tournament,
            match_id = intent.match_id,
            left = left,
            right = right,
            agree_state = agree_state,
            proof = proof,
        }
    )
end

local function prepare_proof(
    intent,
    context,
    machine_logs,
    allow_invalid_claims
)
    local action = "prove leaf"
    local current, level = engagement(
        context,
        intent.tournament,
        intent.match_id,
        intent.commitment,
        intent.side,
        intent.match_state,
        action
    )
    assert(current.live.timeout._tag == Domain.TimeoutDisposition.NONE
        and intent.match_state._tag == Domain.LiveMatchState.SEALED_LEAF,
        "prove-leaf intent no longer matches the accepted snapshot")
    local left, right = root_children(level, action)
    local divergence = intent.match_state.divergence
    local proof, post_state = machine_logs(
        divergence.agree_state,
        divergence.coordinate.cycle
    )
    local expected = intent.side == Domain.MatchSide.ONE
        and divergence.final_state_one
        or divergence.final_state_two
    assert(allow_invalid_claims or post_state == expected,
        "prove-leaf machine post-state disagrees with local final state")
    return prepared(Fulfiller.PreparedAction.PROVE_LEAF, {
        tournament = intent.tournament,
        match_id = intent.match_id,
        left = left,
        right = right,
        proof = proof,
    })
end

local function prepare_propagation(intent, context)
    local action = "propagate child"
    local child = assert(
        context:snapshot_at(intent.child_tournament),
        "propagation child is absent from local semantic path"
    )
    assert(child.standing._tag == Domain.TournamentStanding.INNER_WINNER
        and child.standing.child_commitment == intent.child_winner
        and child.standing.parent_commitment == intent.parent_commitment,
        "propagation intent disagrees with child standing")
    local parent = assert(child.parent,
        "propagation child is missing parent provenance")
    assert(parent.parent_tournament == intent.parent_tournament
        and Domain.same_match_id(parent.parent_match, intent.parent_match)
        and parent.parent_commitment == intent.parent_commitment
        and parent.parent_side == intent.parent_side,
        "propagation intent disagrees with child parent provenance")

    local _, level = local_level(
        context,
        intent.parent_tournament,
        intent.parent_commitment,
        action
    )
    local left, right = root_children(level, action)
    return prepared(Fulfiller.PreparedAction.PROPAGATE_CHILD, {
        parent_tournament = intent.parent_tournament,
        child_tournament = intent.child_tournament,
        left = left,
        right = right,
    })
end

function Fulfiller.prepare(intent, context, options)
    required(intent, "Hero intent")
    required(context, "Hero context")
    options = options or {}
    if intent._tag == Domain.HeroIntent.JOIN then
        return prepare_join(intent, context)
    end
    if intent._tag == Domain.HeroIntent.CLAIM_TIMEOUT then
        return prepare_timeout(intent, context)
    end
    if intent._tag == Domain.HeroIntent.ADVANCE then
        return prepare_advance(intent, context)
    end
    if intent._tag == Domain.HeroIntent.SEAL_LEAF then
        return prepare_seal(intent, context, false)
    end
    if intent._tag == Domain.HeroIntent.CREATE_CHILD then
        return prepare_seal(intent, context, true)
    end
    if intent._tag == Domain.HeroIntent.PROVE_LEAF then
        local machine_logs = options.machine_logs
        if not machine_logs then
            local machine_path =
                required(options.machine_path, "machine path")
            local inputs = required(options.inputs, "machine inputs")
            machine_logs = function(agree_state, cycle)
                return Machine.get_logs(
                    machine_path,
                    agree_state,
                    cycle,
                    inputs
                )
            end
        end
        return prepare_proof(
            intent,
            context,
            machine_logs,
            options.allow_invalid_claims == true
        )
    end
    if intent._tag == Domain.HeroIntent.PROPAGATE_CHILD then
        return prepare_propagation(intent, context)
    end
    error("unknown Hero intent " .. tostring(intent._tag), 2)
end

return Fulfiller
