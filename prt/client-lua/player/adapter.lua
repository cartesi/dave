local bint = require "utils.bint" (256)
local Domain = require "player.domain"
local Hash = require "cryptography.hash"

-- Strict boundary between the observer ABI plus structural fold and the
-- wire-independent domain. The transport supplies decoded observer DTOs; this
-- module rejects every inconsistent combination before a planner can see it.
local Adapter = {}

Adapter.MatchPhase = {
    ABSENT = "absent",
    BISECTING = "bisecting",
    READY_TO_SEAL = "ready_to_seal",
    SEALED = "sealed",
}

Adapter.View = {
    DESCRIPTOR = {
        name = "tournamentDescriptor",
        signature = "tournamentDescriptor()",
    },
    STANDING = {
        name = "tournamentStanding",
        signature = "tournamentStanding()",
    },
    TIMEOUT = {
        name = "classifyMatchTimeout",
        signature = "classifyMatchTimeout((bytes32,bytes32))",
    },
    BISECTING = {
        name = "bisectingMatch",
        signature = "bisectingMatch(bytes32)",
    },
    READY = {
        name = "readyToSealMatch",
        signature = "readyToSealMatch(bytes32)",
    },
    SEALED = {
        name = "sealedMatch",
        signature = "sealedMatch(bytes32)",
    },
}

local ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function normalize_address(value, name)
    name = name or "address"
    assert(type(value) == "string"
        and value:match("^0[xX][%da-fA-F][%da-fA-F]+$")
        and #value == 42,
        name .. " must be a 20-byte hex address")
    return value:lower()
end

Adapter.normalize_address = normalize_address

local function same(left, right)
    return left == right
end

local function is_zero_uint(value)
    if type(value) == "number" then
        return value == 0
    end
    if type(value) == "string" then
        local hexadecimal = value:match("^0[xX]([%da-fA-F]+)$")
        return hexadecimal ~= nil and hexadecimal:match("^0*$") ~= nil
    end
    return getmetatable(value) == bint and bint.iszero(value)
end

local function require_zero_hash(view, field, value)
    assert(Hash:is_of_type_hash(value), view .. "." .. field .. " is not a hash")
    assert(value:is_zero(),
        view .. " returned noncanonical inactive field " .. field)
end

local function require_zero_uint(view, field, value)
    assert(is_zero_uint(value),
        view .. " returned noncanonical inactive field " .. field)
end

local function decode_match_phase(value)
    local phases = {
        [0] = Adapter.MatchPhase.ABSENT,
        [1] = Adapter.MatchPhase.BISECTING,
        [2] = Adapter.MatchPhase.READY_TO_SEAL,
        [3] = Adapter.MatchPhase.SEALED,
    }
    local phase = phases[value]
    assert(phase, "unknown match phase discriminant " .. tostring(value))
    return phase
end

local function decode_kind(value)
    if value == 0 then
        return Domain.TournamentKind.LEAF
    end
    if value == 1 then
        return Domain.TournamentKind.NON_LEAF
    end
    error("unknown tournament kind discriminant " .. tostring(value), 2)
end

local function decode_side(value)
    if value == 0 then
        return Domain.MatchSide.ONE
    end
    if value == 1 then
        return Domain.MatchSide.TWO
    end
    error("unknown commitment side discriminant " .. tostring(value), 2)
end

local function abi_words(raw, expected, view)
    assert(type(raw) == "string" and raw:match("^0[xX][%da-fA-F]*$"),
        view .. " returned malformed ABI data")
    local body = raw:sub(3)
    assert(#body == expected * 64,
        string.format("%s returned %d ABI words, expected %d",
            view, #body // 64, expected))
    local words = {}
    for index = 1, expected do
        words[index] = body:sub((index - 1) * 64 + 1, index * 64):lower()
    end
    return words
end

local function word_hash(word)
    return Hash:from_digest_hex("0x" .. word)
end

local function word_uint(word)
    return "0x" .. word
end

local function word_small(word, bits, name)
    local prefix = word:sub(1, 64 - bits // 4)
    assert(prefix:match("^0*$"), name .. " exceeds uint" .. tostring(bits))
    local value = tonumber(word:sub(65 - bits // 4), 16)
    assert(value and math.type(value) == "integer" and value >= 0,
        name .. " does not fit a Lua integer")
    return value
end

local function word_bool(word, name)
    if word:match("^0*$") then
        return false
    end
    if word:match("^0*1$") then
        return true
    end
    error(name .. " is not a canonical ABI boolean", 2)
end

-- Provider-free decoding for the six static observer return shapes.
function Adapter.decode_result(view, raw)
    required(view, "observer view")
    local name = required(view.name, "observer view name")
    if view == Adapter.View.DESCRIPTOR then
        local words = abi_words(raw, 6, name)
        return {
            initial_hash = word_hash(words[1]),
            base_cycle = word_uint(words[2]),
            log2_stride = word_small(words[3], 64, name .. ".log2Stride"),
            height = word_small(words[4], 64, name .. ".height"),
            level = word_small(words[5], 64, name .. ".level"),
            kind = word_small(words[6], 8, name .. ".kind"),
        }
    end
    if view == Adapter.View.STANDING then
        local words = abi_words(raw, 7, name)
        return {
            standing = word_small(words[1], 8, name .. ".standing"),
            accepts_joins = word_bool(words[2], name .. ".acceptsJoins"),
            has_candidate = word_bool(words[3], name .. ".hasCandidate"),
            candidate = word_hash(words[4]),
            final_state = word_hash(words[5]),
            parent_commitment = word_hash(words[6]),
            finished_at = word_small(words[7], 64, name .. ".finishedAt"),
        }
    end
    if view == Adapter.View.TIMEOUT then
        local words = abi_words(raw, 3, name)
        return {
            actual_phase = word_small(words[1], 8, name .. ".actualPhase"),
            outcome = word_small(words[2], 8, name .. ".outcome"),
            deferred_charge = word_uint(words[3]),
        }
    end
    if view == Adapter.View.BISECTING then
        local words = abi_words(raw, 8, name)
        return {
            actual_phase = word_small(words[1], 8, name .. ".actualPhase"),
            revealing_parent = word_hash(words[2]),
            waiting_left = word_hash(words[3]),
            waiting_right = word_hash(words[4]),
            segment_start_position = word_uint(words[5]),
            segment_start_cycle = word_uint(words[6]),
            current_height =
                word_small(words[7], 64, name .. ".currentHeight"),
            responder = word_small(words[8], 8, name .. ".responder"),
        }
    end
    if view == Adapter.View.READY then
        local words = abi_words(raw, 7, name)
        return {
            actual_phase = word_small(words[1], 8, name .. ".actualPhase"),
            revealing_parent = word_hash(words[2]),
            waiting_left = word_hash(words[3]),
            waiting_right = word_hash(words[4]),
            segment_start_position = word_uint(words[5]),
            segment_start_cycle = word_uint(words[6]),
            responder = word_small(words[7], 8, name .. ".responder"),
        }
    end
    if view == Adapter.View.SEALED then
        local words = abi_words(raw, 6, name)
        return {
            actual_phase = word_small(words[1], 8, name .. ".actualPhase"),
            agree_state = word_hash(words[2]),
            divergence_position = word_uint(words[3]),
            divergence_cycle = word_uint(words[4]),
            final_state_one = word_hash(words[5]),
            final_state_two = word_hash(words[6]),
        }
    end
    error("unknown observer view " .. tostring(name), 2)
end

local function decode_descriptor(tournament_fold, wire)
    local wire_kind = decode_kind(required(wire.kind, "descriptor kind"))
    assert(wire.level == tournament_fold.level,
        string.format(
            "descriptor level %s disagrees with fold level %s",
            tostring(wire.level),
            tostring(tournament_fold.level)
        ))
    local descriptor = Domain.descriptor {
        address = tournament_fold.address,
        level = wire.level,
        kind = wire_kind,
        initial_hash = wire.initial_hash,
        base_cycle = wire.base_cycle,
        log2_stride = wire.log2_stride,
        height = wire.height,
    }
    return descriptor
end

local function candidate_shape(wire)
    local standing = required(wire.standing, "standing discriminant")
    assert(type(wire.accepts_joins) == "boolean",
        "standing acceptsJoins must be a boolean")
    assert(type(wire.has_candidate) == "boolean",
        "standing hasCandidate must be a boolean")
    assert(Hash:is_of_type_hash(wire.candidate),
        "standing candidate must be a hash")
    assert(Hash:is_of_type_hash(wire.final_state),
        "standing finalState must be a hash")
    assert(Hash:is_of_type_hash(wire.parent_commitment),
        "standing parentCommitment must be a hash")
    local shape = {
        [2] = true,
        [3] = false,
        [4] = true,
        [5] = false,
        [6] = true,
    }
    assert(standing >= 0 and standing <= 6,
        "unknown tournament standing discriminant " .. tostring(standing))
    local expected = shape[standing]
    if expected ~= nil then
        assert(wire.has_candidate == expected,
            string.format(
                "standing %d has invalid hasCandidate value %s",
                standing,
                tostring(wire.has_candidate)
            ))
    end
    if wire.has_candidate then
        return wire.candidate
    end
    require_zero_hash("tournamentStanding", "candidate", wire.candidate)
    return nil
end

local function terminal_shape(wire, expected_candidate)
    assert(wire.accepts_joins == false,
        string.format(
            "standing %d has invalid acceptsJoins value %s",
            wire.standing,
            tostring(wire.accepts_joins)
        ))
    assert(wire.has_candidate == expected_candidate,
        string.format(
            "standing %d has invalid hasCandidate value %s",
            wire.standing,
            tostring(wire.has_candidate)
        ))
    if wire.standing ~= 4 then
        require_zero_hash(
            "tournamentStanding",
            "parentCommitment",
            wire.parent_commitment
        )
    end
end

local function require_finished_at_shape(wire)
    local finished_at = required(wire.finished_at, "standing finishedAt")
    assert(type(finished_at) == "number"
        and math.type(finished_at) == "integer"
        and finished_at >= 0,
        "standing finishedAt must be a nonnegative Lua integer")
    if wire.standing <= 1 then
        assert(finished_at == 0,
            string.format(
                "standing %d requires zero finishedAt",
                wire.standing
            ))
    else
        assert(finished_at ~= 0,
            string.format(
                "standing %d requires nonzero finishedAt",
                wire.standing
            ))
    end
end

local function decode_standing(
    fold,
    tournament_fold,
    descriptor,
    parent_match,
    wire
)
    local candidate = candidate_shape(wire)
    require_finished_at_shape(wire)
    local expected_candidate = fold:candidate(
        tournament_fold.address
    )
    assert(same(candidate, expected_candidate),
        "standing candidate disagrees with fold candidate")

    local standing
    if wire.standing == 0 then
        require_zero_hash("tournamentStanding", "finalState", wire.final_state)
        require_zero_hash(
            "tournamentStanding",
            "parentCommitment",
            wire.parent_commitment
        )
        standing = Domain.matches_active(
            candidate,
            wire.accepts_joins
                and Domain.JoinDisposition.OPEN
                or Domain.JoinDisposition.CLOSED
        )
    elseif wire.standing == 1 then
        assert(wire.accepts_joins,
            "awaiting-closure standing must accept joins")
        require_zero_hash("tournamentStanding", "finalState", wire.final_state)
        require_zero_hash(
            "tournamentStanding",
            "parentCommitment",
            wire.parent_commitment
        )
        standing = Domain.awaiting_closure(candidate)
    elseif wire.standing == 2 then
        terminal_shape(wire, true)
        local commitment = assert(
            tournament_fold.commitments[candidate],
            "root winner candidate is absent from fold"
        )
        assert(same(wire.final_state, commitment.final_state),
            "root winner final state disagrees with joined commitment record")
        standing = Domain.root_winner(candidate, wire.final_state)
    elseif wire.standing == 3 then
        terminal_shape(wire, false)
        require_zero_hash("tournamentStanding", "finalState", wire.final_state)
        standing = Domain.root_failed()
    elseif wire.standing == 4 then
        terminal_shape(wire, true)
        local commitment = assert(
            tournament_fold.commitments[candidate],
            "inner winner candidate is absent from fold"
        )
        assert(same(wire.final_state, commitment.final_state),
            "inner winner final state disagrees with joined commitment record")
        assert(parent_match,
            "inner winner standing used without a folded parent match")
        assert(same(wire.parent_commitment, parent_match.commitment_one)
            or same(wire.parent_commitment, parent_match.commitment_two),
            "inner winner does not map to folded parent match")
        standing =
            Domain.inner_winner(wire.parent_commitment, candidate)
    elseif wire.standing == 5 then
        terminal_shape(wire, false)
        require_zero_hash("tournamentStanding", "finalState", wire.final_state)
        standing = Domain.inner_eliminable_no_candidate()
    else
        terminal_shape(wire, true)
        require_zero_hash("tournamentStanding", "finalState", wire.final_state)
        standing = Domain.inner_eliminable_winner_expired(candidate)
    end

    local root_only = standing._tag == Domain.TournamentStanding.ROOT_WINNER
        or standing._tag == Domain.TournamentStanding.ROOT_FAILED
    local inner_only = standing._tag == Domain.TournamentStanding.INNER_WINNER
        or standing._tag == Domain.TournamentStanding.INNER_ELIMINABLE
    assert(not root_only or descriptor.level == 0,
        "root-only standing used for an inner tournament")
    assert(not inner_only or descriptor.level ~= 0,
        "inner-only standing used for a root tournament")
    return standing
end

local function decode_timeout(wire)
    local phase = decode_match_phase(required(
        wire.actual_phase,
        "timeout actual phase"
    ))
    local outcome = required(wire.outcome, "timeout outcome")
    local charge = required(wire.deferred_charge, "timeout deferred charge")
    local disposition
    if outcome == 0 then
        disposition = Domain.timeout_none()
    elseif outcome == 1 then
        disposition = Domain.timeout_one_wins(charge)
    elseif outcome == 2 then
        disposition = Domain.timeout_two_wins(charge)
    elseif outcome == 3 then
        disposition = Domain.timeout_eliminate_both()
    else
        error("unknown timeout outcome discriminant " .. tostring(outcome), 2)
    end

    if phase == Adapter.MatchPhase.ABSENT then
        assert(outcome == 0 and is_zero_uint(charge),
            "absent match timeout must be NONE with zero charge")
    end
    if outcome == 0 or outcome == 3 then
        assert(is_zero_uint(charge),
            string.format(
                "timeout outcome %d requires zero deferred charge",
                outcome
            ))
    end
    return {
        phase = phase,
        disposition = disposition,
        trace = wire._trace,
    }
end

local function require_zero_bisecting(wire)
    local view = "bisectingMatch"
    require_zero_hash(view, "revealingParent", wire.revealing_parent)
    require_zero_hash(view, "waitingLeft", wire.waiting_left)
    require_zero_hash(view, "waitingRight", wire.waiting_right)
    require_zero_uint(view, "segmentStartPosition", wire.segment_start_position)
    require_zero_uint(view, "segmentStartCycle", wire.segment_start_cycle)
    require_zero_uint(view, "currentHeight", wire.current_height)
    require_zero_uint(view, "responder", wire.responder)
end

local function require_zero_ready(wire)
    local view = "readyToSealMatch"
    require_zero_hash(view, "revealingParent", wire.revealing_parent)
    require_zero_hash(view, "waitingLeft", wire.waiting_left)
    require_zero_hash(view, "waitingRight", wire.waiting_right)
    require_zero_uint(view, "segmentStartPosition", wire.segment_start_position)
    require_zero_uint(view, "segmentStartCycle", wire.segment_start_cycle)
    require_zero_uint(view, "responder", wire.responder)
end

local function require_zero_sealed(wire)
    local view = "sealedMatch"
    require_zero_hash(view, "agreeState", wire.agree_state)
    require_zero_uint(view, "divergencePosition", wire.divergence_position)
    require_zero_uint(view, "divergenceCycle", wire.divergence_cycle)
    require_zero_hash(view, "finalStateOne", wire.final_state_one)
    require_zero_hash(view, "finalStateTwo", wire.final_state_two)
end

local function projection_phase(
    timeout,
    wire,
    expected,
    view,
    zero,
    match_id_hash
)
    local phase = decode_match_phase(required(
        wire.actual_phase,
        view .. " actual phase"
    ))
    if phase ~= expected then
        zero(wire)
    end
    if phase ~= timeout.phase or phase ~= expected then
        local timeout_trace = timeout.trace or {}
        local projection_trace = wire._trace or {}
        error(string.format(
            "%s projection phase %s disagrees with timeout phase %s"
                .. " for match %s at timeout head %s"
                .. " (timeout argument %s), projection head %s"
                .. " (projection argument %s)",
            view,
            phase,
            timeout.phase,
            tostring(match_id_hash),
            tostring(timeout_trace.head),
            tostring(timeout_trace.argument),
            tostring(projection_trace.head),
            tostring(projection_trace.argument)
        ), 2)
    end
end

local function unresolved(wire, remaining_height, responder)
    return {
        revealing_parent = wire.revealing_parent,
        waiting_children =
            Domain.waiting_children(wire.waiting_left, wire.waiting_right),
        coordinate = Domain.coordinate(
            wire.segment_start_position,
            wire.segment_start_cycle
        ),
        remaining_height = remaining_height,
        responder = responder,
    }
end

local function decode_bisecting(timeout, wire, match_id_hash)
    projection_phase(
        timeout,
        wire,
        Adapter.MatchPhase.BISECTING,
        "bisectingMatch",
        require_zero_bisecting,
        match_id_hash
    )
    return Domain.bisecting(unresolved(
        wire,
        wire.current_height,
        decode_side(wire.responder)
    ))
end

local function decode_ready(timeout, wire, kind, match_id_hash)
    projection_phase(
        timeout,
        wire,
        Adapter.MatchPhase.READY_TO_SEAL,
        "readyToSealMatch",
        require_zero_ready,
        match_id_hash
    )
    local fields = unresolved(wire, 1, decode_side(wire.responder))
    if kind == Domain.TournamentKind.LEAF then
        return Domain.ready_to_seal_leaf(fields)
    end
    return Domain.ready_to_delegate(fields)
end

local function decode_sealed(timeout, wire, kind, child, match_id_hash)
    projection_phase(
        timeout,
        wire,
        Adapter.MatchPhase.SEALED,
        "sealedMatch",
        require_zero_sealed,
        match_id_hash
    )
    local divergence = Domain.divergence {
        agree_state = wire.agree_state,
        coordinate = Domain.coordinate(
            wire.divergence_position,
            wire.divergence_cycle
        ),
        final_state_one = wire.final_state_one,
        final_state_two = wire.final_state_two,
    }
    if kind == Domain.TournamentKind.LEAF and child == nil then
        return Domain.sealed_leaf(divergence)
    end
    if kind == Domain.TournamentKind.NON_LEAF and child ~= nil then
        return Domain.awaiting_child(divergence, child)
    end
    error("live match " .. tostring(match_id_hash)
        .. " carries an impossible child relationship", 2)
end

local function validate_match_event_history(descriptor, match_fold, state)
    local remaining_height
    local revealing_parent
    local waiting_left
    local segment_start_position
    if state._tag == Domain.LiveMatchState.BISECTING then
        remaining_height = state.remaining_height
        revealing_parent = state.revealing_parent
        waiting_left = state.waiting_children.left
        segment_start_position = state.coordinate.leaf_position
    elseif state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
        or state._tag == Domain.LiveMatchState.READY_TO_DELEGATE
    then
        remaining_height = 1
        revealing_parent = state.revealing_parent
        waiting_left = state.waiting_children.left
        segment_start_position = state.coordinate.leaf_position
    else
        assert(state._tag == Domain.LiveMatchState.SEALED_LEAF
            or state._tag == Domain.LiveMatchState.AWAITING_CHILD,
            "unknown live match state")
        -- Sealing emits no breadcrumb and does not count as MatchAdvanced.
        remaining_height = 1
    end

    local expected_advances = descriptor.height - remaining_height
    assert(match_fold.advances == expected_advances,
        string.format(
            "live match %s has %d folded MatchAdvanced events, expected %d",
            tostring(match_fold.id_hash),
            match_fold.advances,
            expected_advances
        ))

    if revealing_parent ~= nil then
        assert(same(match_fold.last_other_parent, revealing_parent),
            "folded otherParent breadcrumb disagrees with projection")
        assert(same(match_fold.last_left_node, waiting_left),
            "folded leftNode breadcrumb disagrees with projection")
        assert(bint.eq(
            match_fold.last_segment_start_position,
            segment_start_position
        ), "folded segmentStartPosition breadcrumb disagrees with projection")
    end
end

local function folded_parent_match(fold, tournament_fold)
    if tournament_fold.parent == nil then
        return nil
    end
    local parent = assert(
        fold:tournament(tournament_fold.parent.tournament),
        "child tournament has no folded parent"
    )
    return assert(
        fold:match_by_id_hash(
            parent.address,
            tournament_fold.parent.match_id_hash
        ),
        "child tournament has no folded parent match"
    )
end

local function fold_reachable(fold, tournament_fold, observations)
    if tournament_fold.parent == nil then
        return true
    end
    if observations[tournament_fold.parent.tournament] == nil then
        return false
    end
    local parent_match = folded_parent_match(fold, tournament_fold)
    return parent_match.deleted == nil
end

local function observe_tournament(transport, fold, tournament_fold, head)
    local descriptor = decode_descriptor(
        tournament_fold,
        transport:observer_call(
            tournament_fold.address,
            Adapter.View.DESCRIPTOR,
            nil,
            head
        )
    )
    local parent_fold_match = folded_parent_match(fold, tournament_fold)
    local parent_match = parent_fold_match and parent_fold_match.id or nil
    local standing = decode_standing(
        fold,
        tournament_fold,
        descriptor,
        parent_match,
        transport:observer_call(
            tournament_fold.address,
            Adapter.View.STANDING,
            nil,
            head
        )
    )

    local matches = {}
    for _, match_fold in ipairs(fold:live_matches(tournament_fold.address)) do
        assert(same(
            match_fold.id_hash,
            match_fold.id.commitment_one:join(
                match_fold.id.commitment_two
            )
        ), "folded match id hash disagrees with its full id")
        local timeout = decode_timeout(transport:observer_call(
            tournament_fold.address,
            Adapter.View.TIMEOUT,
            match_fold.id,
            head
        ))
        assert(timeout.phase ~= Adapter.MatchPhase.ABSENT,
            "fold sees live match but observer reports it absent")

        local state
        if timeout.phase == Adapter.MatchPhase.BISECTING then
            state = decode_bisecting(
                timeout,
                transport:observer_call(
                    tournament_fold.address,
                    Adapter.View.BISECTING,
                    match_fold.id_hash,
                    head
                ),
                match_fold.id_hash
            )
        elseif timeout.phase == Adapter.MatchPhase.READY_TO_SEAL then
            state = decode_ready(
                timeout,
                transport:observer_call(
                    tournament_fold.address,
                    Adapter.View.READY,
                    match_fold.id_hash,
                    head
                ),
                descriptor.kind,
                match_fold.id_hash
            )
        else
            state = decode_sealed(
                timeout,
                transport:observer_call(
                    tournament_fold.address,
                    Adapter.View.SEALED,
                    match_fold.id_hash,
                    head
                ),
                descriptor.kind,
                match_fold.inner_tournament,
                match_fold.id_hash
            )
        end

        local child = match_fold.inner_tournament
        local valid_topology = descriptor.kind == Domain.TournamentKind.LEAF
            and child == nil
            and (state._tag == Domain.LiveMatchState.BISECTING
                or state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
                or state._tag == Domain.LiveMatchState.SEALED_LEAF)
            or descriptor.kind == Domain.TournamentKind.NON_LEAF
            and ((child == nil
                    and (state._tag == Domain.LiveMatchState.BISECTING
                        or state._tag
                            == Domain.LiveMatchState.READY_TO_DELEGATE))
                or child ~= nil
                    and state._tag == Domain.LiveMatchState.AWAITING_CHILD
                    and state.child_tournament == child)
        assert(valid_topology,
            "live match carries an impossible child relationship")
        validate_match_event_history(descriptor, match_fold, state)

        local observed = Domain.observed_match(
            match_fold.id_hash,
            match_fold.id,
            Domain.live(state, timeout.disposition)
        )
        assert(matches[match_fold.id_hash] == nil,
            "observer returned a duplicate match")
        matches[match_fold.id_hash] = observed
    end

    local ordered = {}
    for _, match_fold in ipairs(fold:live_matches(tournament_fold.address)) do
        table.insert(ordered, assert(matches[match_fold.id_hash]))
    end
    return Domain.tournament_observation(descriptor, standing, ordered)
end

local function validate_parent_topology(
    fold,
    tournament_fold,
    observations,
    child
)
    if tournament_fold.parent == nil then
        return
    end
    local parent_address = tournament_fold.parent.tournament
    local parent_match_hash = tournament_fold.parent.match_id_hash
    local parent_fold_match = folded_parent_match(fold, tournament_fold)
    assert(parent_fold_match.deleted == nil,
        "child tournament has no live folded parent match")
    assert(parent_fold_match.inner_tournament == tournament_fold.address,
        "child tournament disagrees with folded parent topology")

    local parent = assert(
        observations[parent_address],
        "child tournament has no reachable parent observation"
    )
    local parent_match = assert(
        parent.matches[parent_match_hash],
        "child tournament parent match is absent from observation"
    )
    local awaiting = parent_match.live.state
    assert(awaiting._tag == Domain.LiveMatchState.AWAITING_CHILD
        and awaiting.child_tournament == tournament_fold.address
        and child.descriptor.level == parent.descriptor.level + 1
        and same(
            child.descriptor.initial_hash,
            awaiting.divergence.agree_state
        )
        and bint.eq(
            child.descriptor.base_cycle,
            awaiting.divergence.coordinate.cycle
        ),
        "child tournament disagrees with parent match topology")

    if child.standing._tag == Domain.TournamentStanding.INNER_WINNER then
        local commitment = assert(
            tournament_fold.commitments[child.standing.child_commitment],
            "inner winner is absent from child fold"
        )
        local expected
        if same(
            child.standing.parent_commitment,
            parent_match.id.commitment_one
        ) then
            expected = awaiting.divergence.final_state_one
        elseif same(
            child.standing.parent_commitment,
            parent_match.id.commitment_two
        ) then
            expected = awaiting.divergence.final_state_two
        else
            error("inner winner is outside parent match", 2)
        end
        assert(same(commitment.final_state, expected),
            "inner winner final state disagrees with parent sealed match")
    end
end

-- Observe every currently fold-reachable tournament at one caller-supplied
-- canonical block token. No method in this path is allowed to sample latest.
function Adapter.observe_fold(transport, fold, head)
    required(transport, "observer transport")
    required(fold, "structural fold")
    required(head, "canonical observation head")
    local observations = {}
    for _, tournament_fold in ipairs(fold:tournaments()) do
        assert(
            normalize_address(
                tournament_fold.address,
                "fold tournament address"
            ) == tournament_fold.address,
            "fold tournament address must be normalized lowercase"
        )
        if fold_reachable(fold, tournament_fold, observations) then
            local observation =
                observe_tournament(transport, fold, tournament_fold, head)
            validate_parent_topology(
                fold,
                tournament_fold,
                observations,
                observation
            )
            observations[tournament_fold.address] = observation
        end
    end
    return observations
end

Adapter.ZERO_ADDRESS = ZERO_ADDRESS

return Adapter
