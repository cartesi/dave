local Domain = require "player.domain"
local Fold = require "player.fold"
local GcPlanner = require "player.gc_planner"
local Test = require "tests.testlib"

local E = Fold.Event

local function match_hash(match_id)
    return match_id.commitment_one .. ":" .. match_id.commitment_two
end

local function event(tournament, block, kind)
    return Fold.event(tournament, block, kind)
end

local function build_fold()
    local fold = Fold.new("root", { match_id_hash = match_hash })
    local script = {
        event("root", 1, E.commitment_joined("a", "a-final")),
        event("root", 2, E.commitment_joined("b", "b-final")),
        event("root", 3, E.commitment_joined("c", "c-final")),
        event("root", 4, E.commitment_joined("d", "d-final")),
        event("root", 5, E.match_created("a", "b", "left", "a:b")),
        event("root", 6, E.new_inner_tournament("a:b", "child")),
        event("root", 7, E.match_created("c", "d", "left", "c:d")),
    }
    return fold:apply_all(script)
end

local function descriptor(address, level, levels, initial_hash, base_cycle)
    return Domain.descriptor {
        address = address,
        level = level,
        levels = levels,
        initial_hash = initial_hash,
        base_cycle = base_cycle,
        log2_stride = 0,
        height = 4,
    }
end

local function coordinate(position)
    return Domain.coordinate(position, position)
end

local function divergence()
    return Domain.divergence {
        agree_state = "agree",
        coordinate = coordinate(3),
        final_state_one = "final-a",
        final_state_two = "final-b",
    }
end

local function bisecting(base_cycle)
    return Domain.bisecting {
        revealing_parent = "revealing",
        waiting_children = Domain.waiting_children("left", "right"),
        coordinate = Domain.coordinate(0, base_cycle or 0),
        remaining_height = 2,
        responder = Domain.MatchSide.ONE,
    }
end

local function ready_leaf()
    return Domain.ready_to_seal_leaf {
        revealing_parent = "revealing",
        waiting_children = Domain.waiting_children("left", "right"),
        coordinate = coordinate(0),
        responder = Domain.MatchSide.TWO,
    }
end

local function single_match_fold()
    local fold = Fold.new("root", { match_id_hash = match_hash })
    fold:apply_all {
        event("root", 1, E.commitment_joined("a", "a-final")),
        event("root", 2, E.commitment_joined("b", "b-final")),
        event("root", 3, E.match_created("a", "b", "left", "a:b")),
    }
    return fold
end

local function active_observation(address, level, levels, matches)
    return Domain.tournament_observation(
        descriptor(address, level, levels, "initial", 0),
        Domain.matches_active(nil, Domain.JoinDisposition.CLOSED),
        matches
    )
end

local function observations(child_standing)
    local root_descriptor = descriptor("root", 0, 2, "initial", 0)
    local child_descriptor = descriptor("child", 1, 2, "agree", 3)
    local awaiting = Domain.observed_match(
        "a:b",
        Domain.match_id("a", "b"),
        Domain.live(
            Domain.awaiting_child(divergence(), "child"),
            Domain.timeout_none()
        )
    )
    local eliminate = Domain.observed_match(
        "c:d",
        Domain.match_id("c", "d"),
        Domain.live(
            bisecting(),
            Domain.timeout_eliminate_both()
        )
    )
    return {
        root = Domain.tournament_observation(
            root_descriptor,
            Domain.matches_active(
                nil,
                Domain.JoinDisposition.CLOSED
            ),
            { awaiting, eliminate }
        ),
        child = Domain.tournament_observation(
            child_descriptor,
            child_standing,
            {}
        ),
    }
end

return {
    Test.case("GC preserves fold creation order at the same depth", function()
        local fold = Fold.new("root", { match_id_hash = match_hash })
        fold:apply_all {
            event("root", 1, E.commitment_joined("a", "a-final")),
            event("root", 2, E.commitment_joined("b", "b-final")),
            event("root", 3, E.commitment_joined("c", "c-final")),
            event("root", 4, E.commitment_joined("d", "d-final")),
            event("root", 5, E.match_created("a", "b", "left", "a:b")),
            event("root", 6, E.match_created("c", "d", "left", "c:d")),
        }
        local eliminate = function(id_hash, one, two)
            return Domain.observed_match(
                id_hash,
                Domain.match_id(one, two),
                Domain.live(
                    bisecting(),
                    Domain.timeout_eliminate_both()
                )
            )
        end
        local values = {
            root = active_observation("root", 0, 1, {
                eliminate("a:b", "a", "b"),
                eliminate("c:d", "c", "d"),
            }),
        }

        local intents = GcPlanner.plan(fold, values)
        Test.equal(#intents, 2)
        Test.equal(intents[1].match_id.commitment_one, "a")
        Test.equal(intents[1].match_id.commitment_two, "b")
        Test.equal(intents[2].match_id.commitment_one, "c")
        Test.equal(intents[2].match_id.commitment_two, "d")
    end),

    Test.case("GC emits child elimination before shallower match cleanup", function()
        local fold = build_fold()
        local intents = GcPlanner.plan(
            fold,
            observations(Domain.inner_eliminable_no_candidate())
        )
        Test.equal(#intents, 2)
        Test.equal(intents[1]._tag, Domain.GcIntent.ELIMINATE_CHILD)
        Test.equal(intents[1].parent_tournament, "root")
        Test.equal(intents[1].child_tournament, "child")
        Test.equal(intents[2]._tag, Domain.GcIntent.ELIMINATE_MATCH)
        Test.equal(intents[2].tournament, "root")
        Test.equal(intents[2].match_id.commitment_one, "c")
        Test.equal(intents[2].match_id.commitment_two, "d")
    end),

    Test.case("GC recursively finds cleanup in a non-eliminable child", function()
        local fold = build_fold()
        fold:apply_all {
            event("child", 8, E.commitment_joined("e", "e-final")),
            event("child", 9, E.commitment_joined("f", "f-final")),
            event("child", 10, E.match_created("e", "f", "left", "e:f")),
        }

        local values = observations(
            Domain.inner_eliminable_no_candidate()
        )
        local child_descriptor = values.child.descriptor
        values.child = Domain.tournament_observation(
            child_descriptor,
            Domain.matches_active(
                nil,
                Domain.JoinDisposition.CLOSED
            ),
            {
                Domain.observed_match(
                    "e:f",
                    Domain.match_id("e", "f"),
                    Domain.live(
                        bisecting(3),
                        Domain.timeout_eliminate_both()
                    )
                ),
            }
        )

        local intents = GcPlanner.plan(fold, values)
        Test.equal(#intents, 2)
        Test.equal(intents[1]._tag, Domain.GcIntent.ELIMINATE_MATCH)
        Test.equal(intents[1].tournament, "child")
        Test.equal(intents[2]._tag, Domain.GcIntent.ELIMINATE_MATCH)
        Test.equal(intents[2].tournament, "root")
    end),

    Test.case("GC globally prioritizes a deeper later branch", function()
        local fold = Fold.new("root", { match_id_hash = match_hash })
        fold:apply_all {
            event("root", 1, E.commitment_joined("a", "a-final")),
            event("root", 2, E.commitment_joined("b", "b-final")),
            event("root", 3, E.commitment_joined("c", "c-final")),
            event("root", 4, E.commitment_joined("d", "d-final")),
            event("root", 5, E.match_created("c", "d", "left", "c:d")),
            event("root", 6, E.match_created("a", "b", "left", "a:b")),
            event("root", 7, E.new_inner_tournament("a:b", "child")),
            event("child", 8, E.commitment_joined("e", "e-final")),
            event("child", 9, E.commitment_joined("f", "f-final")),
            event("child", 10, E.match_created("e", "f", "left", "e:f")),
        }

        local root = Domain.tournament_observation(
            descriptor("root", 0, 2, "initial", 0),
            Domain.matches_active(nil, Domain.JoinDisposition.CLOSED),
            {
                Domain.observed_match(
                    "c:d",
                    Domain.match_id("c", "d"),
                    Domain.live(
                        bisecting(),
                        Domain.timeout_eliminate_both()
                    )
                ),
                Domain.observed_match(
                    "a:b",
                    Domain.match_id("a", "b"),
                    Domain.live(
                        Domain.awaiting_child(divergence(), "child"),
                        Domain.timeout_none()
                    )
                ),
            }
        )
        local child = Domain.tournament_observation(
            descriptor("child", 1, 2, "agree", 3),
            Domain.matches_active(nil, Domain.JoinDisposition.CLOSED),
            {
                Domain.observed_match(
                    "e:f",
                    Domain.match_id("e", "f"),
                    Domain.live(
                        bisecting(3),
                        Domain.timeout_eliminate_both()
                    )
                ),
            }
        )

        local intents = GcPlanner.plan(fold, {
            root = root,
            child = child,
        })
        Test.equal(#intents, 2)
        Test.equal(intents[1].tournament, "child")
        Test.equal(intents[1].match_id.commitment_one, "e")
        Test.equal(intents[2].tournament, "root")
        Test.equal(intents[2].match_id.commitment_one, "c")
    end),

    Test.case("GC directly eliminates a WinnerExpired child", function()
        local fold = build_fold()
        fold:apply(event(
            "child",
            8,
            E.commitment_joined("expired", "expired-final")
        ))
        local intents = GcPlanner.plan(
            fold,
            observations(
                Domain.inner_eliminable_winner_expired("expired")
            )
        )
        Test.equal(#intents, 2)
        Test.equal(intents[1]._tag, Domain.GcIntent.ELIMINATE_CHILD)
        Test.equal(intents[1].parent_tournament, "root")
        Test.equal(intents[1].child_tournament, "child")
    end),

    Test.case("GC does not eliminate non-eliminable child standings", function()
        local standings = {
            Domain.awaiting_closure("candidate"),
            Domain.inner_winner("a", "child-winner"),
        }
        for _, standing in ipairs(standings) do
            local intents = GcPlanner.plan(
                build_fold(),
                observations(standing)
            )
            Test.equal(#intents, 1)
            Test.equal(
                intents[1]._tag,
                Domain.GcIntent.ELIMINATE_MATCH
            )
            Test.equal(intents[1].tournament, "root")
            Test.equal(intents[1].match_id.commitment_one, "c")
        end
    end),

    Test.case("GC ignores non-eliminable timeout dispositions", function()
        local fold = single_match_fold()
        local responder_two = Domain.bisecting {
            revealing_parent = "revealing",
            waiting_children = Domain.waiting_children("left", "right"),
            coordinate = coordinate(0),
            remaining_height = 3,
            responder = Domain.MatchSide.TWO,
        }
        local lives = {
            Domain.live(bisecting(), Domain.timeout_none()),
            Domain.live(responder_two, Domain.timeout_one_wins(3)),
            Domain.live(bisecting(), Domain.timeout_two_wins(3)),
        }
        for _, live in ipairs(lives) do
            local values = {
                root = active_observation("root", 0, 1, {
                    Domain.observed_match(
                        "a:b",
                        Domain.match_id("a", "b"),
                        live
                    ),
                }),
            }
            Test.equal(#GcPlanner.plan(fold, values), 0)
        end
    end),

    Test.case("GC cleans ready and sealed EliminateBoth matches", function()
        local fold = single_match_fold()
        local lives = {
            Domain.live(
                ready_leaf(),
                Domain.timeout_eliminate_both()
            ),
            Domain.live(
                Domain.sealed_leaf(divergence()),
                Domain.timeout_eliminate_both()
            ),
        }
        for _, live in ipairs(lives) do
            local values = {
                root = active_observation("root", 0, 1, {
                    Domain.observed_match(
                        "a:b",
                        Domain.match_id("a", "b"),
                        live
                    ),
                }),
            }
            local intents = GcPlanner.plan(fold, values)
            Test.equal(#intents, 1)
            Test.equal(
                intents[1]._tag,
                Domain.GcIntent.ELIMINATE_MATCH
            )
            Test.equal(intents[1].tournament, "root")
            Test.equal(intents[1].match_id.commitment_one, "a")
            Test.equal(intents[1].match_id.commitment_two, "b")
        end
    end),

    Test.case("GC fails closed on incomplete semantic observations", function()
        local fold = build_fold()
        local values = observations(
            Domain.inner_eliminable_no_candidate()
        )
        values.child = nil
        Test.error_like("missing its semantic observation", function()
            GcPlanner.plan(fold, values)
        end)

        values = observations(Domain.inner_eliminable_no_candidate())
        values.root.matches["c:d"] = nil
        Test.error_like("missing its semantic observation", function()
            GcPlanner.plan(fold, values)
        end)
    end),
}
