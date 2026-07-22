local Context = require "player.context"
local Domain = require "player.domain"
local Fold = require "player.fold"
local Hash = require "cryptography.hash"
local MerkleBuilder = require "cryptography.merkle_builder"
local Test = require "tests.testlib"

local function digest(byte)
    return Hash:from_digest_hex(
        "0x" .. string.rep(string.format("%02x", byte), 32)
    )
end

local function address(byte)
    return "0x" .. string.rep(string.format("%02x", byte), 20)
end

local function tree(initial_hash, first_leaf, height)
    local builder = MerkleBuilder:new()
    for offset = 0, (1 << height) - 1 do
        builder:add(digest(first_leaf + offset))
    end
    return builder:build(initial_hash)
end

local function descriptor(at, initial_hash, level, levels, base_cycle)
    return Domain.descriptor {
        address = at,
        level = level,
        levels = levels,
        initial_hash = initial_hash,
        base_cycle = base_cycle or 0,
        log2_stride = 0,
        height = 2,
    }
end

local function builder_for(level_trees)
    local calls = {}
    return {
        build = function(_, base_cycle, level, stride, height)
            table.insert(calls, {
                base_cycle = base_cycle,
                level = level,
                stride = stride,
                height = height,
            })
            return assert(level_trees[level], "unexpected level")
        end,
        calls = calls,
    }
end

local function observation(desc, standing, matches)
    return Domain.tournament_observation(desc, standing, matches or {})
end

local function root_fixture()
    local root = address(1)
    local initial = digest(1)
    local local_tree = tree(initial, 10, 2)
    local desc = descriptor(root, initial, 0, 1)
    return root, initial, local_tree, desc
end

return {
    Test.case("context projects all four actor-relative commitment standings", function()
        local root, initial, local_tree, desc = root_fixture()
        local opponent = digest(30)

        local not_joined_fold = Fold.new(root)
        local not_joined = Context.assemble {
            fold = not_joined_fold,
            observations = {
                [root] = observation(
                    desc,
                    Domain.awaiting_closure(nil)
                ),
            },
            commitment_builder = builder_for { [0] = local_tree },
            root_initial_hash = initial,
        }
        Test.equal(
            not_joined.snapshot.local_standing._tag,
            Domain.LocalCommitmentStanding.NOT_JOINED
        )

        local candidate_fold = Fold.new(root)
        candidate_fold:apply(Fold.event(
            root,
            1,
            Fold.Event.commitment_joined(
                local_tree.root_hash,
                digest(40)
            )
        ))
        local candidate = Context.assemble {
            fold = candidate_fold,
            observations = {
                [root] = observation(
                    desc,
                    Domain.awaiting_closure(local_tree.root_hash)
                ),
            },
            commitment_builder = builder_for { [0] = local_tree },
        }
        Test.equal(
            candidate.snapshot.local_standing._tag,
            Domain.LocalCommitmentStanding.CANDIDATE
        )

        local engaged_fold = Fold.new(root)
        for _, commitment in ipairs { local_tree.root_hash, opponent } do
            engaged_fold:apply(Fold.event(
                root,
                1,
                Fold.Event.commitment_joined(commitment, digest(41))
            ))
        end
        engaged_fold:apply(Fold.event(
            root,
            2,
            Fold.Event.match_created(
                local_tree.root_hash,
                opponent,
                digest(42),
                local_tree.root_hash:join(opponent)
            )
        ))
        local match = engaged_fold:live_matches(root)[1]
        local live = Domain.live(Domain.bisecting {
            revealing_parent = local_tree.root_hash,
            waiting_children =
                Domain.waiting_children(digest(50), digest(51)),
            coordinate = Domain.coordinate(0, 0),
            remaining_height = 2,
            responder = Domain.MatchSide.ONE,
        }, Domain.timeout_none())
        local engaged = Context.assemble {
            fold = engaged_fold,
            observations = {
                [root] = observation(
                    desc,
                    Domain.matches_active(
                        nil,
                        Domain.JoinDisposition.OPEN
                    ),
                    {
                        Domain.observed_match(
                            match.id_hash,
                            match.id,
                            live
                        ),
                    }
                ),
            },
            commitment_builder = builder_for { [0] = local_tree },
        }
        Test.equal(
            engaged.snapshot.local_standing._tag,
            Domain.LocalCommitmentStanding.ENGAGED
        )

        engaged_fold:apply(Fold.event(
            root,
            3,
            Fold.Event.match_deleted(
                match.id_hash,
                Fold.MatchDeletionReason.TIMEOUT,
                Fold.WinnerCommitment.NEITHER
            )
        ))
        local eliminated = Context.assemble {
            fold = engaged_fold,
            observations = {
                [root] = observation(
                    desc,
                    Domain.awaiting_closure(nil)
                ),
            },
            commitment_builder = builder_for { [0] = local_tree },
        }
        Test.equal(
            eliminated.snapshot.local_standing._tag,
            Domain.LocalCommitmentStanding.ELIMINATED
        )
        Test.equal(
            eliminated.snapshot.local_standing.record.reason,
            Domain.EliminationReason.TIMEOUT
        )
    end),

    Test.case("context follows only the local awaiting-child path", function()
        local root = address(1)
        local child = address(2)
        local root_initial = digest(1)
        local child_initial = digest(2)
        local root_tree = tree(root_initial, 10, 2)
        local child_tree = tree(child_initial, 20, 2)
        local opponent = digest(30)
        local fold = Fold.new(root)
        for _, commitment in ipairs { root_tree.root_hash, opponent } do
            fold:apply(Fold.event(
                root,
                1,
                Fold.Event.commitment_joined(commitment, digest(31))
            ))
        end
        fold:apply(Fold.event(
            root,
            2,
            Fold.Event.match_created(
                root_tree.root_hash,
                opponent,
                digest(32),
                root_tree.root_hash:join(opponent)
            )
        ))
        local match = fold:live_matches(root)[1]
        fold:apply(Fold.event(
            root,
            3,
            Fold.Event.new_inner_tournament(match.id_hash, child)
        ))

        local divergence = Domain.divergence {
            agree_state = child_initial,
            coordinate = Domain.coordinate(0, 0),
            final_state_one = digest(40),
            final_state_two = digest(41),
        }
        local root_observation = observation(
            descriptor(root, root_initial, 0, 2),
            Domain.matches_active(nil, Domain.JoinDisposition.OPEN),
            {
                Domain.observed_match(
                    match.id_hash,
                    match.id,
                    Domain.live(
                        Domain.awaiting_child(divergence, child),
                        Domain.timeout_none()
                    )
                ),
            }
        )
        local child_observation = observation(
            descriptor(child, child_initial, 1, 2),
            Domain.awaiting_closure(nil)
        )
        local commitment_builder = builder_for {
            [0] = root_tree,
            [1] = child_tree,
        }
        local context = Context.assemble {
            fold = fold,
            observations = {
                [root] = root_observation,
                [child] = child_observation,
            },
            commitment_builder = commitment_builder,
            root_initial_hash = root_initial,
        }

        Test.equal(context.snapshot.child.descriptor.address, child)
        Test.equal(
            context.snapshot.child.parent.parent_tournament,
            root
        )
        Test.truthy(Domain.same_match_id(
            context.snapshot.child.parent.parent_match,
            match.id
        ))
        Test.equal(context:level(root).commitment, root_tree)
        Test.equal(context:level(child).commitment, child_tree)
        Test.equal(#commitment_builder.calls, 2)
    end),

    Test.case("context rejects a wrong root anchor before planning", function()
        local root, _, local_tree, desc = root_fixture()
        Test.error_like("external anchor", function()
            Context.assemble {
                fold = Fold.new(root),
                observations = {
                    [root] = observation(
                        desc,
                        Domain.awaiting_closure(nil)
                    ),
                },
                commitment_builder =
                    builder_for { [0] = local_tree },
                root_initial_hash = digest(99),
            }
        end)
    end),
}
