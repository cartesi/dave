local Domain = require "player.domain"
local bint = require "utils.bint" (256)

-- Pure structural index over the six tournament event types.
--
-- The fold owns enumeration, provenance, and the event-authoritative match
-- elimination schedule. It does not interpret raw match slots, clocks, or
-- tournament results.
local Fold = {}
Fold.__index = Fold

Fold.EventKind = {
    COMMITMENT_JOINED = "commitment_joined",
    MATCH_CREATED = "match_created",
    MATCH_ADVANCED = "match_advanced",
    LEAF_MATCH_SEALED = "leaf_match_sealed",
    MATCH_DELETED = "match_deleted",
    NEW_INNER_TOURNAMENT = "new_inner_tournament",
}

Fold.MatchDeletionReason = {
    STEP = "step",
    TIMEOUT = "timeout",
    CHILD_TOURNAMENT = "child_tournament",
}

Fold.WinnerCommitment = {
    NEITHER = "neither",
    ONE = "one",
    TWO = "two",
}

Fold.CommitmentStatus = {
    NOT_JOINED = "not_joined",
    CANDIDATE = "candidate",
    ENGAGED = "engaged",
    ELIMINATED = "eliminated",
}

Fold.Event = {}

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function nonnegative_integer(value, name)
    assert(type(value) == "number" and math.type(value) == "integer"
        and value >= 0, name .. " must be a nonnegative Lua integer")
    return value
end

local MAX_U64 = (bint.one() << 64) - 1
local MAX_U64_DECIMAL = "18446744073709551615"

local function uint64(value, name)
    required(value, name)
    if type(value) == "number" then
        nonnegative_integer(value, name)
    elseif type(value) == "string" then
        local decimal = value:match("^(%d+)$")
        local hexadecimal = value:match("^0[xX]([%da-fA-F]+)$")
        assert(decimal or hexadecimal,
            name .. " must be an unsigned integer")
        if hexadecimal then
            hexadecimal = hexadecimal:gsub("^0+", "")
            assert(#hexadecimal <= 16, name .. " exceeds uint64")
        else
            decimal = decimal:gsub("^0+", "")
            assert(#decimal < #MAX_U64_DECIMAL
                or #decimal == #MAX_U64_DECIMAL
                and decimal <= MAX_U64_DECIMAL,
                name .. " exceeds uint64")
        end
    else
        assert(getmetatable(value) == bint,
            name .. " must be an unsigned integer")
    end
    local parsed = bint(value)
    assert(bint.ule(parsed, MAX_U64), name .. " exceeds uint64")
    return parsed
end

local function same(left, right)
    return left == right
end

local function copy_array(values)
    local copied = {}
    for index, value in ipairs(values) do
        copied[index] = value
    end
    return copied
end

local function copy_match(match)
    if not match then
        return nil
    end
    local deleted = match.deleted and {
        reason = match.deleted.reason,
        winner = match.deleted.winner,
        deleted_at_block = match.deleted.deleted_at_block,
    } or nil
    return {
        id = Domain.match_id(
            match.id.commitment_one,
            match.id.commitment_two
        ),
        id_hash = match.id_hash,
        created_at_block = match.created_at_block,
        eliminable_at = match.eliminable_at and
            bint(match.eliminable_at) or nil,
        advances = match.advances,
        last_other_parent = match.last_other_parent,
        last_left_node = match.last_left_node,
        last_segment_start_position =
            bint(match.last_segment_start_position),
        inner_tournament = match.inner_tournament,
        deleted = deleted,
    }
end

local function copy_tournament(tournament)
    if not tournament then
        return nil
    end

    local commitments = {}
    for root, commitment in pairs(tournament.commitments) do
        commitments[root] = {
            root = commitment.root,
            final_state = commitment.final_state,
            joined_at_block = commitment.joined_at_block,
            latest_match = commitment.latest_match,
        }
    end

    local matches = {}
    for index, match in ipairs(tournament.matches) do
        matches[index] = copy_match(match)
    end

    local match_index = {}
    for id_hash, index in pairs(tournament.match_index) do
        match_index[id_hash] = index
    end

    return {
        address = tournament.address,
        parent = tournament.parent and {
            tournament = tournament.parent.tournament,
            match_id_hash = tournament.parent.match_id_hash,
        } or nil,
        level = tournament.level,
        commitments = commitments,
        commitment_order = copy_array(tournament.commitment_order),
        matches = matches,
        match_index = match_index,
    }
end

local function default_match_id_hash(match_id)
    local one = match_id.commitment_one
    assert(type(one) == "table" and type(one.join) == "function",
        "fold needs a match_id_hash function for non-Hash commitments")
    return one:join(match_id.commitment_two)
end

local function event_kind(tag, fields)
    fields = fields or {}
    fields._tag = tag
    return fields
end

function Fold.Event.commitment_joined(root, final_state)
    return event_kind(Fold.EventKind.COMMITMENT_JOINED, {
        root = required(root, "commitment root"),
        final_state = required(final_state, "commitment final state"),
    })
end

function Fold.Event.match_created(
    commitment_one,
    commitment_two,
    left_of_two,
    emitted_match_id_hash,
    eliminable_at
)
    return event_kind(Fold.EventKind.MATCH_CREATED, {
        commitment_one = required(commitment_one, "commitment one"),
        commitment_two = required(commitment_two, "commitment two"),
        left_of_two = required(left_of_two, "left child of commitment two"),
        emitted_match_id_hash = required(
            emitted_match_id_hash,
            "emitted match id hash"
        ),
        eliminable_at = uint64(eliminable_at, "match elimination block"),
    })
end

function Fold.Event.match_advanced(
    match_id_hash,
    other_parent,
    left_node,
    segment_start_position,
    eliminable_at
)
    return event_kind(Fold.EventKind.MATCH_ADVANCED, {
        match_id_hash = required(match_id_hash, "match id hash"),
        other_parent = required(other_parent, "other parent"),
        left_node = required(left_node, "left node"),
        segment_start_position =
            required(segment_start_position, "segment start position"),
        eliminable_at = uint64(eliminable_at, "match elimination block"),
    })
end

function Fold.Event.leaf_match_sealed(match_id_hash, eliminable_at)
    return event_kind(Fold.EventKind.LEAF_MATCH_SEALED, {
        match_id_hash = required(match_id_hash, "match id hash"),
        eliminable_at = uint64(eliminable_at, "match elimination block"),
    })
end

function Fold.Event.match_deleted(match_id_hash, reason, winner)
    return event_kind(Fold.EventKind.MATCH_DELETED, {
        match_id_hash = required(match_id_hash, "match id hash"),
        reason = reason,
        winner = winner,
    })
end

function Fold.Event.new_inner_tournament(match_id_hash, child)
    return event_kind(Fold.EventKind.NEW_INNER_TOURNAMENT, {
        match_id_hash = required(match_id_hash, "match id hash"),
        child = required(child, "child tournament"),
    })
end

function Fold.event(tournament, block, kind)
    return {
        tournament = required(tournament, "event tournament"),
        block = nonnegative_integer(block, "event block"),
        kind = required(kind, "event kind"),
    }
end

local function tournament_record(address, parent, level)
    return {
        address = address,
        parent = parent,
        level = level,
        commitments = {},
        commitment_order = {},
        matches = {},
        match_index = {},
    }
end

function Fold.new(root, options)
    options = options or {}
    required(root, "root tournament")
    local tournaments = {
        [root] = tournament_record(root, nil, 0),
    }
    return setmetatable({
        _root = root,
        _tournaments = tournaments,
        _order = { root },
        _last_block = nil,
        _match_id_hash = options.match_id_hash or default_match_id_hash,
    }, Fold)
end

function Fold:root()
    return self._root
end

function Fold:addresses()
    return copy_array(self._order)
end

function Fold:tournament(address)
    return copy_tournament(self._tournaments[address])
end

function Fold:tournaments()
    local records = {}
    for _, address in ipairs(self._order) do
        table.insert(records, copy_tournament(self._tournaments[address]))
    end
    return records
end

function Fold:match_by_id_hash(tournament_address, match_id_hash)
    local tournament = self._tournaments[tournament_address]
    if not tournament then
        return nil
    end
    local index = tournament.match_index[match_id_hash]
    return index and copy_match(tournament.matches[index]) or nil
end

function Fold:live_matches(tournament_address)
    local tournament = assert(
        self._tournaments[tournament_address],
        "unknown tournament"
    )
    local matches = {}
    for _, match in ipairs(tournament.matches) do
        if not match.deleted then
            table.insert(matches, copy_match(match))
        end
    end
    return matches
end

local function mutable_match(tournament, match_id_hash)
    local index = tournament.match_index[match_id_hash]
    assert(index, "event for an unknown match")
    return tournament.matches[index]
end

local function validate_deletion(reason, winner)
    assert(reason == Fold.MatchDeletionReason.STEP
        or reason == Fold.MatchDeletionReason.TIMEOUT
        or reason == Fold.MatchDeletionReason.CHILD_TOURNAMENT,
        "unknown match deletion reason")
    assert(winner == Fold.WinnerCommitment.NEITHER
        or winner == Fold.WinnerCommitment.ONE
        or winner == Fold.WinnerCommitment.TWO,
        "unknown winner commitment")
    assert(reason ~= Fold.MatchDeletionReason.STEP
        or winner ~= Fold.WinnerCommitment.NEITHER,
        "a step deletion must record one surviving commitment")
end

function Fold:apply(event)
    required(event, "tournament event")
    nonnegative_integer(event.block, "event block")
    if self._last_block then
        assert(event.block >= self._last_block,
            "tournament events are not in block order")
    end

    local tournament = self._tournaments[event.tournament]
    assert(tournament, "event for an undiscovered tournament")
    local kind = event.kind
    required(kind, "event kind")

    if kind._tag == Fold.EventKind.COMMITMENT_JOINED then
        assert(not tournament.commitments[kind.root],
            "commitment joined twice")
        tournament.commitments[kind.root] = {
            root = kind.root,
            final_state = kind.final_state,
            joined_at_block = event.block,
            latest_match = nil,
        }
        table.insert(tournament.commitment_order, kind.root)
    elseif kind._tag == Fold.EventKind.MATCH_CREATED then
        local match_id =
            Domain.match_id(kind.commitment_one, kind.commitment_two)
        local match_id_hash = self._match_id_hash(match_id)
        assert(same(kind.emitted_match_id_hash, match_id_hash),
            "emitted match id hash disagrees with ordered commitments")
        assert(not tournament.match_index[match_id_hash],
            "match created twice")

        local one = tournament.commitments[kind.commitment_one]
        local two = tournament.commitments[kind.commitment_two]
        assert(one, "match created for unjoined commitment one")
        assert(two, "match created for unjoined commitment two")

        local index = #tournament.matches + 1
        local match = {
            id = match_id,
            id_hash = match_id_hash,
            created_at_block = event.block,
            eliminable_at = uint64(
                kind.eliminable_at,
                "match elimination block"
            ),
            advances = 0,
            last_other_parent = kind.commitment_one,
            last_left_node = kind.left_of_two,
            -- Bisection starts at leaf position zero; advances replace this
            -- with the emitted post-advance segment start position.
            last_segment_start_position = 0,
            inner_tournament = nil,
            deleted = nil,
        }
        tournament.matches[index] = match
        tournament.match_index[match_id_hash] = index
        one.latest_match = index
        two.latest_match = index
    elseif kind._tag == Fold.EventKind.MATCH_ADVANCED then
        local match = mutable_match(tournament, kind.match_id_hash)
        assert(not match.deleted, "advance on a deleted match")
        match.advances = match.advances + 1
        match.last_other_parent = kind.other_parent
        match.last_left_node = kind.left_node
        -- Clone: bint values are mutable, and the caller retains the event.
        match.last_segment_start_position = bint(kind.segment_start_position)
        match.eliminable_at = uint64(
            kind.eliminable_at,
            "match elimination block"
        )
    elseif kind._tag == Fold.EventKind.LEAF_MATCH_SEALED then
        local match = mutable_match(tournament, kind.match_id_hash)
        assert(not match.deleted, "leaf seal on a deleted match")
        assert(not match.inner_tournament,
            "leaf seal on a match with an inner tournament")
        match.eliminable_at = uint64(
            kind.eliminable_at,
            "match elimination block"
        )
    elseif kind._tag == Fold.EventKind.MATCH_DELETED then
        validate_deletion(kind.reason, kind.winner)
        local match = mutable_match(tournament, kind.match_id_hash)
        assert(not match.deleted, "match deleted twice")
        match.deleted = {
            reason = kind.reason,
            winner = kind.winner,
            deleted_at_block = event.block,
        }
        match.eliminable_at = nil
    elseif kind._tag == Fold.EventKind.NEW_INNER_TOURNAMENT then
        local match = mutable_match(tournament, kind.match_id_hash)
        assert(not match.deleted,
            "inner tournament created from a deleted match")
        assert(not match.inner_tournament,
            "match created more than one inner tournament")
        assert(not self._tournaments[kind.child],
            "inner tournament discovered twice")

        match.inner_tournament = kind.child
        match.eliminable_at = nil
        local parent = {
            tournament = tournament.address,
            match_id_hash = kind.match_id_hash,
        }
        self._tournaments[kind.child] =
            tournament_record(kind.child, parent, tournament.level + 1)
        table.insert(self._order, kind.child)
    else
        error("unknown tournament event kind", 2)
    end

    self._last_block = event.block
    return self
end

function Fold:apply_all(events)
    for _, event in ipairs(events) do
        self:apply(event)
    end
    return self
end

local function survivor_side(winner)
    if winner == Fold.WinnerCommitment.ONE then
        return Domain.MatchSide.ONE
    end
    if winner == Fold.WinnerCommitment.TWO then
        return Domain.MatchSide.TWO
    end
    return nil
end

function Fold:commitment_status(tournament_address, root)
    local tournament = assert(
        self._tournaments[tournament_address],
        "unknown tournament"
    )
    local commitment = tournament.commitments[root]
    if not commitment then
        return { _tag = Fold.CommitmentStatus.NOT_JOINED }
    end
    if not commitment.latest_match then
        return { _tag = Fold.CommitmentStatus.CANDIDATE }
    end

    local match = assert(tournament.matches[commitment.latest_match])
    if not match.deleted then
        return {
            _tag = Fold.CommitmentStatus.ENGAGED,
            match = copy_match(match),
        }
    end

    local survivor = survivor_side(match.deleted.winner)
    local side = Domain.side_for(root, match.id)
    if survivor == side then
        return {
            _tag = Fold.CommitmentStatus.CANDIDATE,
            match = copy_match(match),
        }
    end
    return {
        _tag = Fold.CommitmentStatus.ELIMINATED,
        match = copy_match(match),
        reason = match.deleted.reason,
        survivor = survivor,
    }
end

function Fold:candidate(tournament_address)
    local tournament = assert(
        self._tournaments[tournament_address],
        "unknown tournament"
    )
    local candidate = nil
    for _, root in ipairs(tournament.commitment_order) do
        local status = self:commitment_status(tournament_address, root)
        if status._tag == Fold.CommitmentStatus.CANDIDATE then
            assert(candidate == nil,
                "fold derives more than one dangling candidate")
            candidate = root
        end
    end
    return candidate
end

return Fold
