local bint = require "utils.bint" (256)

-- Wire-independent semantic values shared by the pure Lua planners.
--
-- ABI discriminants and canonical-zero validation belong in the future
-- adapter. This module starts after that boundary: its constructors reject
-- impossible domain combinations before policy can inspect them.
local Domain = {}

Domain.MatchSide = {
    ONE = "one",
    TWO = "two",
}

Domain.TournamentKind = {
    LEAF = "leaf",
    NON_LEAF = "non_leaf",
}

Domain.LiveMatchState = {
    BISECTING = "bisecting",
    READY_TO_SEAL_LEAF = "ready_to_seal_leaf",
    READY_TO_DELEGATE = "ready_to_delegate",
    SEALED_LEAF = "sealed_leaf",
    AWAITING_CHILD = "awaiting_child",
}

Domain.TimeoutDisposition = {
    NONE = "none",
    ONE_WINS = "one_wins",
    TWO_WINS = "two_wins",
    ELIMINATE_BOTH = "eliminate_both",
}

Domain.LocalCommitmentStanding = {
    NOT_JOINED = "not_joined",
    CANDIDATE = "candidate",
    ENGAGED = "engaged",
    ELIMINATED = "eliminated",
}

Domain.JoinDisposition = {
    OPEN = "open",
    CLOSED = "closed",
}

Domain.TournamentStanding = {
    MATCHES_ACTIVE = "matches_active",
    AWAITING_CLOSURE = "awaiting_closure",
    ROOT_WINNER = "root_winner",
    ROOT_FAILED = "root_failed",
    INNER_WINNER = "inner_winner",
    INNER_ELIMINABLE = "inner_eliminable",
}

Domain.InnerEliminationReason = {
    NO_CANDIDATE = "no_candidate",
    WINNER_EXPIRED = "winner_expired",
}

Domain.EliminationReason = {
    STEP = "step",
    TIMEOUT = "timeout",
    CHILD_TOURNAMENT = "child_tournament",
}

Domain.HeroDecision = {
    TERMINAL = "terminal",
    WAIT = "wait",
    ACT = "act",
}

Domain.HeroTerminal = {
    WON = "won",
    LOST = "lost",
    FAILED_NO_WINNER = "failed_no_winner",
}

Domain.WaitReason = {
    CANDIDATE_BLOCKED_BY_MATCHES = "candidate_blocked_by_matches",
    AWAITING_TOURNAMENT_CLOSURE = "awaiting_tournament_closure",
    JOINS_CLOSED = "joins_closed",
    OPPONENT_TURN = "opponent_turn",
    OPPONENT_WINS_BY_TIMEOUT = "opponent_wins_by_timeout",
    MATCH_ELIMINABLE = "match_eliminable",
    CHILD_ELIMINABLE = "child_eliminable",
}

Domain.HeroIntent = {
    JOIN = "join",
    CLAIM_TIMEOUT = "claim_timeout",
    ADVANCE = "advance",
    SEAL_LEAF = "seal_leaf",
    CREATE_CHILD = "create_child",
    PROVE_LEAF = "prove_leaf",
    PROPAGATE_CHILD = "propagate_child",
}

Domain.GcIntent = {
    ELIMINATE_MATCH = "eliminate_match",
    ELIMINATE_CHILD = "eliminate_child",
}

local MAX_U64 = (bint.one() << 64) - 1
local MAX_U256_DECIMAL =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935"

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function integer(value, name)
    assert(type(value) == "number" and math.type(value) == "integer",
        name .. " must be a Lua integer")
    return value
end

local function nonnegative_integer(value, name)
    integer(value, name)
    assert(value >= 0, name .. " must be nonnegative")
    return value
end

local function uint256(value, name)
    required(value, name)
    if type(value) == "number" then
        nonnegative_integer(value, name)
    elseif type(value) == "string" then
        local decimal = value:match("^(%d+)$")
        local hexadecimal = value:match("^0[xX]([%da-fA-F]+)$")
        assert(decimal or hexadecimal, name .. " must be an unsigned integer")
        if hexadecimal then
            hexadecimal = hexadecimal:gsub("^0+", "")
            assert(#hexadecimal <= 64, name .. " exceeds uint256")
        else
            decimal = decimal:gsub("^0+", "")
            assert(#decimal < #MAX_U256_DECIMAL
                or #decimal == #MAX_U256_DECIMAL
                and decimal <= MAX_U256_DECIMAL,
                name .. " exceeds uint256")
        end
    else
        assert(getmetatable(value) == bint, name .. " must be an unsigned integer")
    end
    return bint(value)
end

local function instant(value)
    local parsed = uint256(value, "block instant")
    assert(bint.ule(parsed, MAX_U64), "block instant exceeds uint64")
    return parsed
end

local function duration(value)
    local parsed = uint256(value, "block duration")
    assert(bint.ule(parsed, MAX_U64), "block duration exceeds uint64")
    return parsed
end

local function same(left, right)
    return left == right
end

local function assert_tag(value, expected, name)
    assert(type(value) == "table" and value._tag == expected,
        name .. " has the wrong semantic tag")
end

-- Semantic records are mutable Lua tables, while hashes and addresses are
-- opaque value objects. Copy only tagged domain records (and mutable bints) so
-- a retained constructor input cannot mutate a planner snapshot without
-- changing the identity semantics of opaque values.
local function copy_semantic(value, seen)
    if getmetatable(value) == bint then
        return bint(value)
    end
    if type(value) ~= "table" or value._tag == nil then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copied = {}
    seen[value] = copied
    for key, field in pairs(value) do
        copied[key] = copy_semantic(field, seen)
    end
    return copied
end

local function assert_side(side)
    assert(side == Domain.MatchSide.ONE or side == Domain.MatchSide.TWO,
        "unknown match side")
    return side
end

local function is_zero_address(address)
    return type(address) == "string"
        and address:lower() == "0x0000000000000000000000000000000000000000"
end

function Domain.match_id(commitment_one, commitment_two)
    required(commitment_one, "commitment one")
    required(commitment_two, "commitment two")
    assert(not same(commitment_one, commitment_two),
        "a match cannot contain the same commitment twice")
    return {
        _tag = "match_id",
        commitment_one = commitment_one,
        commitment_two = commitment_two,
    }
end

function Domain.same_match_id(left, right)
    return left ~= nil and right ~= nil
        and same(left.commitment_one, right.commitment_one)
        and same(left.commitment_two, right.commitment_two)
end

function Domain.side_for(commitment, match_id)
    assert_tag(match_id, "match_id", "match id")
    if same(commitment, match_id.commitment_one) then
        return Domain.MatchSide.ONE
    end
    if same(commitment, match_id.commitment_two) then
        return Domain.MatchSide.TWO
    end
    error("local commitment is not in the supplied match", 2)
end

function Domain.side_commitment(side, match_id)
    assert_side(side)
    assert_tag(match_id, "match_id", "match id")
    if side == Domain.MatchSide.ONE then
        return match_id.commitment_one
    end
    return match_id.commitment_two
end

function Domain.descriptor(args)
    args = required(args, "descriptor arguments")
    local address = required(args.address, "tournament address")
    assert(not is_zero_address(address), "tournament address must be nonzero")
    local level = nonnegative_integer(args.level, "tournament level")
    local kind = required(args.kind, "tournament kind")
    assert(kind == Domain.TournamentKind.LEAF
        or kind == Domain.TournamentKind.NON_LEAF,
        "unknown tournament kind " .. tostring(kind))

    local height = nonnegative_integer(args.height, "commitment height")
    local log2_stride = nonnegative_integer(args.log2_stride, "log2 stride")
    assert(height > 0, "commitment height must be nonzero")
    assert(height < 256 and log2_stride < 256 and height + log2_stride < 256,
        "commitment coordinate geometry exceeds uint256")

    local base_cycle = uint256(args.base_cycle, "base cycle")
    local maximum_leaf_offset = ((bint.one() << height) - 1) << log2_stride
    local maximum_cycle = base_cycle + maximum_leaf_offset
    assert(not bint.ult(maximum_cycle, base_cycle),
        "tournament cycle range exceeds uint256")

    return {
        _tag = "tournament_descriptor",
        address = address,
        kind = kind,
        level = level,
        initial_hash = required(args.initial_hash, "initial hash"),
        base_cycle = base_cycle,
        log2_stride = log2_stride,
        height = height,
        start_instant = instant(args.start_instant),
        allowance = duration(args.allowance),
    }
end

function Domain.coordinate(leaf_position, cycle)
    return {
        _tag = "match_coordinate",
        leaf_position = uint256(leaf_position, "leaf position"),
        cycle = uint256(cycle, "cycle"),
    }
end

function Domain.waiting_children(left, right)
    return {
        _tag = "waiting_children",
        left = required(left, "waiting left"),
        right = required(right, "waiting right"),
    }
end

local function unresolved_state(tag, args, remaining_height)
    args = required(args, "unresolved match arguments")
    assert_tag(args.coordinate, "match_coordinate", "match coordinate")
    assert_tag(args.waiting_children, "waiting_children", "waiting children")
    return {
        _tag = tag,
        revealing_parent = required(args.revealing_parent, "revealing parent"),
        waiting_children = args.waiting_children,
        coordinate = args.coordinate,
        remaining_height = remaining_height,
        responder = assert_side(args.responder),
    }
end

function Domain.bisecting(args)
    local remaining_height =
        nonnegative_integer(args.remaining_height, "remaining height")
    assert(remaining_height >= 2, "bisecting height must be at least two")
    return unresolved_state(
        Domain.LiveMatchState.BISECTING,
        args,
        remaining_height
    )
end

function Domain.ready_to_seal_leaf(args)
    return unresolved_state(
        Domain.LiveMatchState.READY_TO_SEAL_LEAF,
        args,
        1
    )
end

function Domain.ready_to_delegate(args)
    return unresolved_state(
        Domain.LiveMatchState.READY_TO_DELEGATE,
        args,
        1
    )
end

function Domain.divergence(args)
    args = required(args, "sealed divergence arguments")
    assert_tag(args.coordinate, "match_coordinate", "match coordinate")
    return {
        _tag = "sealed_divergence",
        agree_state = required(args.agree_state, "agree state"),
        coordinate = args.coordinate,
        final_state_one = required(args.final_state_one, "final state one"),
        final_state_two = required(args.final_state_two, "final state two"),
    }
end

function Domain.sealed_leaf(divergence)
    assert_tag(divergence, "sealed_divergence", "sealed divergence")
    return {
        _tag = Domain.LiveMatchState.SEALED_LEAF,
        divergence = divergence,
    }
end

function Domain.awaiting_child(divergence, child_tournament)
    assert_tag(divergence, "sealed_divergence", "sealed divergence")
    required(child_tournament, "child tournament")
    assert(not is_zero_address(child_tournament),
        "child tournament address must be nonzero")
    return {
        _tag = Domain.LiveMatchState.AWAITING_CHILD,
        divergence = divergence,
        child_tournament = child_tournament,
    }
end

function Domain.timeout_none()
    return { _tag = Domain.TimeoutDisposition.NONE }
end

function Domain.timeout_one_wins(deferred_charge)
    return {
        _tag = Domain.TimeoutDisposition.ONE_WINS,
        deferred_charge = duration(deferred_charge),
    }
end

function Domain.timeout_two_wins(deferred_charge)
    return {
        _tag = Domain.TimeoutDisposition.TWO_WINS,
        deferred_charge = duration(deferred_charge),
    }
end

function Domain.timeout_eliminate_both()
    return { _tag = Domain.TimeoutDisposition.ELIMINATE_BOTH }
end

function Domain.timeout_winner(timeout)
    if timeout._tag == Domain.TimeoutDisposition.ONE_WINS then
        return Domain.MatchSide.ONE, timeout.deferred_charge
    end
    if timeout._tag == Domain.TimeoutDisposition.TWO_WINS then
        return Domain.MatchSide.TWO, timeout.deferred_charge
    end
    return nil
end

local function state_responder(state)
    if state._tag == Domain.LiveMatchState.BISECTING
        or state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
        or state._tag == Domain.LiveMatchState.READY_TO_DELEGATE
    then
        return state.responder
    end
    return nil
end

function Domain.live(state, timeout)
    required(state, "live match state")
    required(timeout, "timeout disposition")

    if state._tag == Domain.LiveMatchState.AWAITING_CHILD then
        assert(timeout._tag == Domain.TimeoutDisposition.NONE,
            "an awaiting-child match cannot have a parent-match timeout")
    end

    local winner = Domain.timeout_winner(timeout)
    local responder = state_responder(state)
    assert(not winner or not responder or winner ~= responder,
        "an active timeout winner cannot be the running responder")

    if state._tag == Domain.LiveMatchState.SEALED_LEAF and winner then
        assert(bint.iszero(timeout.deferred_charge),
            "a sealed-leaf timeout winner cannot carry a deferred charge")
    end

    return {
        _tag = "live_match",
        state = state,
        timeout = timeout,
    }
end

local function state_coordinate(state)
    if state._tag == Domain.LiveMatchState.BISECTING
        or state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
        or state._tag == Domain.LiveMatchState.READY_TO_DELEGATE
    then
        return state.coordinate, state.remaining_height, state.responder
    end
    if state._tag == Domain.LiveMatchState.SEALED_LEAF
        or state._tag == Domain.LiveMatchState.AWAITING_CHILD
    then
        return state.divergence.coordinate, nil, nil
    end
    error("unknown live match state", 2)
end

function Domain.validate_live_in(live, descriptor)
    assert_tag(live, "live_match", "live match")
    assert_tag(descriptor, "tournament_descriptor", "tournament descriptor")
    local state = live.state

    local kind_agrees = descriptor.kind == Domain.TournamentKind.LEAF
        and (state._tag == Domain.LiveMatchState.BISECTING
            or state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
            or state._tag == Domain.LiveMatchState.SEALED_LEAF)
        or descriptor.kind == Domain.TournamentKind.NON_LEAF
        and (state._tag == Domain.LiveMatchState.BISECTING
            or state._tag == Domain.LiveMatchState.READY_TO_DELEGATE
            or state._tag == Domain.LiveMatchState.AWAITING_CHILD)
    assert(kind_agrees, "match state does not agree with tournament kind")

    local coordinate, remaining_height, responder = state_coordinate(state)
    local tree_size = bint.one() << descriptor.height
    assert(bint.ult(coordinate.leaf_position, tree_size),
        "match leaf position is outside the commitment tree")

    if remaining_height then
        assert(remaining_height <= descriptor.height,
            "match remaining height exceeds commitment height")
        local advances = descriptor.height - remaining_height
        local expected_responder = advances % 2 == 0
            and Domain.MatchSide.ONE
            or Domain.MatchSide.TWO
        assert(responder == expected_responder,
            "match responder disagrees with commitment-height parity")
        local alignment = bint.one() << remaining_height
        assert(bint.iszero(coordinate.leaf_position % alignment),
            "unresolved match position is misaligned")
    end

    local scaled_position = coordinate.leaf_position << descriptor.log2_stride
    assert(bint.eq(
        scaled_position >> descriptor.log2_stride,
        coordinate.leaf_position
    ), "match cycle scaling overflowed")
    local expected_cycle = descriptor.base_cycle + scaled_position
    assert(not bint.ult(expected_cycle, descriptor.base_cycle),
        "match cycle addition overflowed")
    assert(bint.eq(coordinate.cycle, expected_cycle),
        "match cycle disagrees with descriptor geometry")
    return live
end

function Domain.engagement(local_commitment, match_id, live)
    assert_tag(match_id, "match_id", "match id")
    assert_tag(live, "live_match", "live match")
    return {
        _tag = "engagement",
        match_id = match_id,
        local_side = Domain.side_for(local_commitment, match_id),
        live = live,
    }
end

function Domain.elimination_record(
    local_commitment,
    match_id,
    reason,
    survivor
)
    assert_tag(match_id, "match_id", "match id")
    assert(reason == Domain.EliminationReason.STEP
        or reason == Domain.EliminationReason.TIMEOUT
        or reason == Domain.EliminationReason.CHILD_TOURNAMENT,
        "unknown elimination reason")
    if survivor then
        assert_side(survivor)
    end
    local local_side = Domain.side_for(local_commitment, match_id)
    assert(survivor ~= local_side,
        "an elimination record cannot eliminate the recorded survivor")
    assert(reason ~= Domain.EliminationReason.STEP or survivor ~= nil,
        "a step deletion must record one surviving commitment")
    return {
        _tag = "elimination_record",
        match_id = match_id,
        local_side = local_side,
        reason = reason,
        survivor = survivor,
    }
end

function Domain.not_joined()
    return { _tag = Domain.LocalCommitmentStanding.NOT_JOINED }
end

function Domain.candidate()
    return { _tag = Domain.LocalCommitmentStanding.CANDIDATE }
end

function Domain.engaged(engagement)
    assert_tag(engagement, "engagement", "engagement")
    return {
        _tag = Domain.LocalCommitmentStanding.ENGAGED,
        engagement = engagement,
    }
end

function Domain.eliminated(record)
    assert_tag(record, "elimination_record", "elimination record")
    return {
        _tag = Domain.LocalCommitmentStanding.ELIMINATED,
        record = record,
    }
end

function Domain.matches_active(candidate, joins)
    assert(joins == Domain.JoinDisposition.OPEN
        or joins == Domain.JoinDisposition.CLOSED,
        "unknown join disposition")
    return {
        _tag = Domain.TournamentStanding.MATCHES_ACTIVE,
        candidate = candidate,
        joins = joins,
    }
end

function Domain.awaiting_closure(candidate)
    return {
        _tag = Domain.TournamentStanding.AWAITING_CLOSURE,
        candidate = candidate,
    }
end

function Domain.root_winner(commitment, final_state)
    return {
        _tag = Domain.TournamentStanding.ROOT_WINNER,
        commitment = required(commitment, "root winner commitment"),
        final_state = required(final_state, "root winner final state"),
    }
end

function Domain.root_failed()
    return { _tag = Domain.TournamentStanding.ROOT_FAILED }
end

function Domain.inner_winner(parent_commitment, child_commitment)
    return {
        _tag = Domain.TournamentStanding.INNER_WINNER,
        parent_commitment = required(parent_commitment, "parent commitment"),
        child_commitment = required(child_commitment, "child commitment"),
    }
end

function Domain.inner_eliminable_no_candidate()
    return {
        _tag = Domain.TournamentStanding.INNER_ELIMINABLE,
        reason = Domain.InnerEliminationReason.NO_CANDIDATE,
    }
end

function Domain.inner_eliminable_winner_expired(candidate)
    return {
        _tag = Domain.TournamentStanding.INNER_ELIMINABLE,
        reason = Domain.InnerEliminationReason.WINNER_EXPIRED,
        candidate = required(candidate, "expired child candidate"),
    }
end

function Domain.standing_candidate(standing)
    if standing._tag == Domain.TournamentStanding.MATCHES_ACTIVE
        or standing._tag == Domain.TournamentStanding.AWAITING_CLOSURE
    then
        return standing.candidate
    end
    if standing._tag == Domain.TournamentStanding.ROOT_WINNER then
        return standing.commitment
    end
    if standing._tag == Domain.TournamentStanding.INNER_WINNER then
        return standing.child_commitment
    end
    if standing._tag == Domain.TournamentStanding.INNER_ELIMINABLE
        and standing.reason == Domain.InnerEliminationReason.WINNER_EXPIRED
    then
        return standing.candidate
    end
    return nil
end

function Domain.standing_accepts_joins(standing)
    return standing._tag == Domain.TournamentStanding.AWAITING_CLOSURE
        or standing._tag == Domain.TournamentStanding.MATCHES_ACTIVE
        and standing.joins == Domain.JoinDisposition.OPEN
end

function Domain.standing_has_active_matches(standing)
    return standing._tag == Domain.TournamentStanding.MATCHES_ACTIVE
end

function Domain.parent_link(parent_tournament, parent_match, parent_commitment)
    required(parent_tournament, "parent tournament")
    assert_tag(parent_match, "match_id", "parent match")
    return {
        _tag = "parent_link",
        parent_tournament = parent_tournament,
        parent_match = parent_match,
        parent_commitment = parent_commitment,
        parent_side = Domain.side_for(parent_commitment, parent_match),
    }
end

local function validate_standing_level(descriptor, standing)
    local root_only = standing._tag == Domain.TournamentStanding.ROOT_WINNER
        or standing._tag == Domain.TournamentStanding.ROOT_FAILED
    local inner_only = standing._tag == Domain.TournamentStanding.INNER_WINNER
        or standing._tag == Domain.TournamentStanding.INNER_ELIMINABLE
    assert(not root_only or descriptor.level == 0,
        "root-only standing used for an inner tournament")
    assert(not inner_only or descriptor.level ~= 0,
        "inner-only standing used for a root tournament")
end

function Domain.snapshot(args)
    args = required(args, "snapshot arguments")
    local descriptor = args.descriptor
    local standing = args.standing
    local local_standing = args.local_standing
    assert_tag(descriptor, "tournament_descriptor", "tournament descriptor")
    required(standing, "tournament standing")
    required(local_standing, "local commitment standing")
    validate_standing_level(descriptor, standing)

    if descriptor.level == 0 then
        assert(args.parent == nil, "root tournament snapshot cannot carry a parent")
    else
        assert_tag(args.parent, "parent_link", "parent link")
    end

    if standing._tag == Domain.TournamentStanding.INNER_WINNER then
        local parent_match = args.parent.parent_match
        assert(same(standing.parent_commitment, parent_match.commitment_one)
            or same(standing.parent_commitment, parent_match.commitment_two),
            "inner winner is outside the recorded parent match")
    end

    local local_commitment = required(args.local_commitment, "local commitment")
    local candidate = Domain.standing_candidate(standing)
    local local_is_candidate =
        local_standing._tag == Domain.LocalCommitmentStanding.CANDIDATE
    assert((candidate ~= nil and same(candidate, local_commitment))
        == local_is_candidate,
        "local candidate identity disagrees with tournament standing")

    if local_standing._tag == Domain.LocalCommitmentStanding.ELIMINATED then
        local record = local_standing.record
        assert(same(
            Domain.side_commitment(record.local_side, record.match_id),
            local_commitment
        ), "local elimination identity disagrees with the snapshot commitment")
    end

    local awaiting = nil
    local engagement = nil
    if local_standing._tag == Domain.LocalCommitmentStanding.ENGAGED then
        assert(Domain.standing_has_active_matches(standing),
            "a local engagement requires active matches")
        engagement = local_standing.engagement
        assert(same(
            Domain.side_commitment(engagement.local_side, engagement.match_id),
            local_commitment
        ), "local engagement identity disagrees with the snapshot commitment")
        Domain.validate_live_in(engagement.live, descriptor)
        if engagement.live.state._tag == Domain.LiveMatchState.AWAITING_CHILD then
            awaiting = engagement.live.state
        end
    end

    if awaiting then
        local child = args.child
        assert(child ~= nil, "awaiting-child snapshot is missing its child")
        assert(same(child.descriptor.address, awaiting.child_tournament),
            "recursive child address disagrees with parent match")
        local child_parent = child.parent
        assert(child_parent
            and same(child_parent.parent_tournament, descriptor.address)
            and Domain.same_match_id(child_parent.parent_match, engagement.match_id)
            and same(child_parent.parent_commitment, local_commitment),
            "recursive child provenance disagrees with parent snapshot")
        assert(child.descriptor.level == descriptor.level + 1,
            "recursive child must be exactly one level deeper")
        assert(same(
            child.descriptor.initial_hash,
            awaiting.divergence.agree_state
        ), "recursive child initial hash disagrees with sealed agree state")
        assert(bint.eq(
            child.descriptor.base_cycle,
            awaiting.divergence.coordinate.cycle
        ), "recursive child base cycle disagrees with sealed match cycle")
    else
        assert(args.child == nil,
            "snapshot carries a child outside an awaiting-child engagement")
    end

    local seen = {}
    return {
        _tag = "semantic_snapshot",
        descriptor = copy_semantic(descriptor, seen),
        standing = copy_semantic(standing, seen),
        local_commitment = local_commitment,
        local_standing = copy_semantic(local_standing, seen),
        parent = copy_semantic(args.parent, seen),
        child = copy_semantic(args.child, seen),
    }
end

function Domain.observed_match(id_hash, match_id, live)
    required(id_hash, "match id hash")
    assert_tag(match_id, "match_id", "match id")
    assert_tag(live, "live_match", "live match")
    return {
        _tag = "observed_match",
        id_hash = id_hash,
        id = match_id,
        live = live,
    }
end

function Domain.tournament_observation(descriptor, standing, matches)
    assert_tag(descriptor, "tournament_descriptor", "tournament descriptor")
    required(standing, "tournament standing")
    validate_standing_level(descriptor, standing)
    matches = matches or {}

    local by_id_hash = {}
    local order = {}
    local seen = {}
    for _, observed in ipairs(matches) do
        assert_tag(observed, "observed_match", "observed match")
        assert(by_id_hash[observed.id_hash] == nil,
            "observer returned a duplicate match")
        Domain.validate_live_in(observed.live, descriptor)
        local owned = copy_semantic(observed, seen)
        by_id_hash[owned.id_hash] = owned
        table.insert(order, owned)
    end

    assert(Domain.standing_has_active_matches(standing) == (#order > 0),
        "standing active-match flag disagrees with observed live matches")
    return {
        _tag = "tournament_observation",
        descriptor = copy_semantic(descriptor, seen),
        standing = copy_semantic(standing, seen),
        matches = by_id_hash,
        match_order = order,
    }
end

function Domain.terminal(result)
    return {
        _tag = Domain.HeroDecision.TERMINAL,
        result = result,
    }
end

function Domain.wait(reason, fields)
    fields = fields or {}
    fields._tag = Domain.HeroDecision.WAIT
    fields.reason = reason
    return fields
end

function Domain.act(intent)
    return {
        _tag = Domain.HeroDecision.ACT,
        intent = intent,
    }
end

local function intent(tag, fields)
    fields._tag = tag
    return fields
end

local function copy_match_id(match_id)
    assert_tag(match_id, "match_id", "match id")
    return Domain.match_id(
        match_id.commitment_one,
        match_id.commitment_two
    )
end

local function copy_coordinate(coordinate)
    assert_tag(coordinate, "match_coordinate", "match coordinate")
    return Domain.coordinate(
        coordinate.leaf_position,
        coordinate.cycle
    )
end

local function copy_waiting_children(children)
    assert_tag(children, "waiting_children", "waiting children")
    return Domain.waiting_children(children.left, children.right)
end

local function copy_divergence(divergence)
    assert_tag(divergence, "sealed_divergence", "sealed divergence")
    return Domain.divergence {
        agree_state = divergence.agree_state,
        coordinate = copy_coordinate(divergence.coordinate),
        final_state_one = divergence.final_state_one,
        final_state_two = divergence.final_state_two,
    }
end

local function copy_live_state(state)
    if state._tag == Domain.LiveMatchState.BISECTING then
        return Domain.bisecting {
            revealing_parent = state.revealing_parent,
            waiting_children = copy_waiting_children(state.waiting_children),
            coordinate = copy_coordinate(state.coordinate),
            remaining_height = state.remaining_height,
            responder = state.responder,
        }
    end
    if state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF then
        return Domain.ready_to_seal_leaf {
            revealing_parent = state.revealing_parent,
            waiting_children = copy_waiting_children(state.waiting_children),
            coordinate = copy_coordinate(state.coordinate),
            responder = state.responder,
        }
    end
    if state._tag == Domain.LiveMatchState.READY_TO_DELEGATE then
        return Domain.ready_to_delegate {
            revealing_parent = state.revealing_parent,
            waiting_children = copy_waiting_children(state.waiting_children),
            coordinate = copy_coordinate(state.coordinate),
            responder = state.responder,
        }
    end
    if state._tag == Domain.LiveMatchState.SEALED_LEAF then
        return Domain.sealed_leaf(copy_divergence(state.divergence))
    end
    assert(state._tag == Domain.LiveMatchState.AWAITING_CHILD,
        "unknown live match state")
    return Domain.awaiting_child(
        copy_divergence(state.divergence),
        state.child_tournament
    )
end

local function copy_match_locator(args, state_tag)
    args = required(args, "match intent")
    local match_id = copy_match_id(args.match_id)
    local commitment = required(args.commitment, "intent commitment")
    local side = assert_side(args.side)
    assert(same(Domain.side_commitment(side, match_id), commitment),
        "intent commitment disagrees with its match side")
    assert(type(args.match_state) == "table"
        and args.match_state._tag == state_tag,
        "intent match state has the wrong live-state variant")
    return {
        tournament = required(args.tournament, "intent tournament"),
        match_id = match_id,
        commitment = commitment,
        side = side,
        match_state = copy_live_state(args.match_state),
    }
end

function Domain.join_intent(tournament, commitment)
    return intent(Domain.HeroIntent.JOIN, {
        tournament = required(tournament, "intent tournament"),
        commitment = required(commitment, "intent commitment"),
    })
end

function Domain.timeout_intent(args)
    args = required(args, "timeout intent")
    local match_id = copy_match_id(args.match_id)
    local commitment = required(args.commitment, "intent commitment")
    local survivor = assert_side(args.survivor)
    assert(same(Domain.side_commitment(survivor, match_id), commitment),
        "timeout commitment disagrees with the surviving side")
    return intent(Domain.HeroIntent.CLAIM_TIMEOUT, {
        tournament = required(args.tournament, "intent tournament"),
        match_id = match_id,
        commitment = commitment,
        survivor = survivor,
        deferred_charge = duration(args.deferred_charge),
    })
end

function Domain.advance_intent(args)
    return intent(Domain.HeroIntent.ADVANCE, copy_match_locator(
        args,
        Domain.LiveMatchState.BISECTING
    ))
end

function Domain.seal_intent(args)
    return intent(Domain.HeroIntent.SEAL_LEAF, copy_match_locator(
        args,
        Domain.LiveMatchState.READY_TO_SEAL_LEAF
    ))
end

function Domain.child_intent(args)
    return intent(Domain.HeroIntent.CREATE_CHILD, copy_match_locator(
        args,
        Domain.LiveMatchState.READY_TO_DELEGATE
    ))
end

function Domain.proof_intent(args)
    return intent(Domain.HeroIntent.PROVE_LEAF, copy_match_locator(
        args,
        Domain.LiveMatchState.SEALED_LEAF
    ))
end

function Domain.propagation_intent(args)
    args = required(args, "propagation intent")
    local parent_match = copy_match_id(args.parent_match)
    local parent_commitment =
        required(args.parent_commitment, "parent commitment")
    local parent_side = assert_side(args.parent_side)
    assert(same(
        Domain.side_commitment(parent_side, parent_match),
        parent_commitment
    ), "parent commitment disagrees with its match side")
    return intent(Domain.HeroIntent.PROPAGATE_CHILD, {
        parent_tournament =
            required(args.parent_tournament, "parent tournament"),
        child_tournament =
            required(args.child_tournament, "child tournament"),
        parent_match = parent_match,
        parent_commitment = parent_commitment,
        parent_side = parent_side,
        child_winner = required(args.child_winner, "child winner"),
    })
end

function Domain.eliminate_match_intent(tournament, match_id)
    return intent(Domain.GcIntent.ELIMINATE_MATCH, {
        tournament = required(tournament, "intent tournament"),
        match_id = copy_match_id(match_id),
    })
end

function Domain.eliminate_child_intent(parent_tournament, child_tournament)
    return intent(Domain.GcIntent.ELIMINATE_CHILD, {
        parent_tournament =
            required(parent_tournament, "parent tournament"),
        child_tournament =
            required(child_tournament, "child tournament"),
    })
end

return Domain
