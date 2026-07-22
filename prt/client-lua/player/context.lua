local bint = require "utils.bint" (256)
local Domain = require "player.domain"
local Fold = require "player.fold"
local Hash = require "cryptography.hash"

-- Actor-relative projection of one accepted structural/semantic observation.
--
-- The fold and observer describe the whole dispute. Hero policy needs the
-- commitment built by this client at each reachable level and only the nested
-- child path currently defended by that commitment. Commitment trees remain
-- outside Domain.snapshot because they are fulfillment material, not policy.
local Context = {}
Context.__index = Context

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function same(left, right)
    return left == right
end

local function match_id_hash(match_id)
    return match_id.commitment_one:join(match_id.commitment_two)
end

local function elimination_reason(reason)
    if reason == Fold.MatchDeletionReason.STEP then
        return Domain.EliminationReason.STEP
    end
    if reason == Fold.MatchDeletionReason.TIMEOUT then
        return Domain.EliminationReason.TIMEOUT
    end
    assert(reason == Fold.MatchDeletionReason.CHILD_TOURNAMENT,
        "unknown folded match deletion reason")
    return Domain.EliminationReason.CHILD_TOURNAMENT
end

local function validate_parent_topology(fold, tournament, parent)
    if tournament.address == fold:root() then
        assert(parent == nil and tournament.parent == nil,
            "root tournament carries parent topology")
        return
    end

    assert(parent, "inner tournament is missing its local parent link")
    assert(tournament.parent
        and same(tournament.parent.tournament, parent.parent_tournament)
        and same(
            tournament.parent.match_id_hash,
            match_id_hash(parent.parent_match)
        ),
        "inner tournament local path disagrees with folded parent topology")
end

local function validate_material(descriptor, commitment)
    assert(type(commitment) == "table"
        and Hash:is_of_type_hash(commitment.root_hash),
        "commitment builder returned malformed level material")
    assert(type(commitment.children) == "function"
        and type(commitment.prove_leaf) == "function"
        and type(commitment.last) == "function",
        "commitment builder returned incomplete Merkle material")
    assert(commitment.height == descriptor.height,
        "local commitment height disagrees with tournament descriptor")
    assert(Hash:is_of_type_hash(commitment.implicit_hash)
        and same(commitment.implicit_hash, descriptor.initial_hash),
        "local commitment initial hash disagrees with tournament descriptor")

    local log2_span = descriptor.log2_stride + descriptor.height
    assert(log2_span < 256,
        "local tournament span does not fit uint256 coordinates")
    local span = bint.one() << log2_span
    assert(bint.iszero(descriptor.base_cycle % span),
        "local tournament base cycle is not aligned to its level span")
end

local function project_local_standing(
    fold,
    tournament,
    observation,
    local_commitment
)
    local folded = fold:commitment_status(
        tournament.address,
        local_commitment
    )
    if folded._tag == Fold.CommitmentStatus.NOT_JOINED then
        return Domain.not_joined()
    end
    if folded._tag == Fold.CommitmentStatus.CANDIDATE then
        return Domain.candidate()
    end

    local match = required(folded.match, "folded local match")
    if folded._tag == Fold.CommitmentStatus.ELIMINATED then
        return Domain.eliminated(Domain.elimination_record(
            local_commitment,
            match.id,
            elimination_reason(folded.reason),
            folded.survivor
        ))
    end

    assert(folded._tag == Fold.CommitmentStatus.ENGAGED,
        "unknown folded local commitment status")
    local observed = assert(
        observation.matches[match.id_hash],
        "live folded local match is absent from semantic observation"
    )
    assert(Domain.same_match_id(observed.id, match.id),
        "folded and observed local match identities disagree")
    return Domain.engaged(Domain.engagement(
        local_commitment,
        match.id,
        observed.live
    ))
end

local function assemble_tournament(
    tournament_address,
    parent,
    fold,
    observations,
    commitment_builder,
    levels,
    expected_root_initial_hash
)
    local tournament = assert(
        fold:tournament(tournament_address),
        "local path tournament is absent from structural fold"
    )
    validate_parent_topology(fold, tournament, parent)

    local observation = assert(
        observations[tournament_address],
        "local path tournament is absent from semantic observations"
    )
    local descriptor = observation.descriptor
    assert(descriptor.address == tournament_address,
        "semantic descriptor address disagrees with local path")
    assert(descriptor.level == tournament.level,
        "semantic descriptor level disagrees with structural fold")
    if tournament_address == fold:root()
        and expected_root_initial_hash ~= nil
    then
        assert(same(descriptor.initial_hash, expected_root_initial_hash),
            "root tournament initial hash disagrees with external anchor")
    end

    local commitment = commitment_builder:build(
        descriptor.base_cycle,
        descriptor.level,
        descriptor.log2_stride,
        descriptor.height
    )
    validate_material(descriptor, commitment)
    assert(levels[tournament_address] == nil,
        "local path visits a tournament more than once")
    levels[tournament_address] = {
        descriptor = descriptor,
        commitment = commitment,
    }

    local local_commitment = commitment.root_hash
    local local_standing = project_local_standing(
        fold,
        tournament,
        observation,
        local_commitment
    )

    local child
    if local_standing._tag == Domain.LocalCommitmentStanding.ENGAGED then
        local engagement = local_standing.engagement
        local state = engagement.live.state
        if state._tag == Domain.LiveMatchState.AWAITING_CHILD then
            local link = Domain.parent_link(
                tournament_address,
                engagement.match_id,
                local_commitment
            )
            child = assemble_tournament(
                state.child_tournament,
                link,
                fold,
                observations,
                commitment_builder,
                levels,
                expected_root_initial_hash
            )
        end
    end

    return Domain.snapshot {
        descriptor = descriptor,
        standing = observation.standing,
        local_commitment = local_commitment,
        local_standing = local_standing,
        parent = parent,
        child = child,
    }
end

function Context.assemble(args)
    args = required(args, "context arguments")
    local fold = required(args.fold, "structural fold")
    local observations =
        required(args.observations, "semantic observations")
    local commitment_builder =
        required(args.commitment_builder, "commitment builder")
    local levels = {}
    local snapshot = assemble_tournament(
        fold:root(),
        nil,
        fold,
        observations,
        commitment_builder,
        levels,
        args.root_initial_hash
    )
    return setmetatable({
        snapshot = snapshot,
        levels = levels,
    }, Context)
end

function Context:snapshot_at(tournament)
    local snapshot = self.snapshot
    while snapshot do
        if snapshot.descriptor.address == tournament then
            return snapshot
        end
        snapshot = snapshot.child
    end
    return nil
end

function Context:level(tournament)
    return self.levels[tournament]
end

return Context
