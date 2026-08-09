local bint = require "utils.bint" (256)
local Domain = require "player.domain"
local Test = require "tests.testlib"

local LEAF = Domain.TournamentKind.LEAF
local NON_LEAF = Domain.TournamentKind.NON_LEAF

local function descriptor(args)
    args = args or {}
    return Domain.descriptor {
        address = args.address or "root",
        level = args.level or 0,
        kind = args.kind or LEAF,
        initial_hash = args.initial_hash or "initial",
        base_cycle = args.base_cycle or 0,
        log2_stride = args.log2_stride or 0,
        height = args.height or 4,
    }
end

local function coordinate(position)
    return Domain.coordinate(position, position)
end

local function bisecting()
    return Domain.bisecting {
        revealing_parent = "revealing",
        waiting_children = Domain.waiting_children("left", "right"),
        coordinate = coordinate(0),
        remaining_height = 2,
        responder = Domain.MatchSide.ONE,
    }
end

local function divergence()
    return Domain.divergence {
        agree_state = "agree",
        coordinate = coordinate(3),
        final_state_one = "final-one",
        final_state_two = "final-two",
    }
end

return {
    Test.case("descriptor accepts kind and checks uint256 geometry", function()
        local rows = {
            { level = 0, kind = LEAF },
            { level = 0, kind = NON_LEAF },
            { level = 1, kind = LEAF },
            { level = 1, kind = NON_LEAF },
        }
        for _, row in ipairs(rows) do
            local value = descriptor(row)
            Test.equal(value.kind, row.kind)
        end

        local invalid = {
            {
                message = "unknown tournament kind",
                args = { kind = "branch" },
            },
            {
                message = "height must be nonzero",
                args = { height = 0 },
            },
            {
                message = "geometry exceeds uint256",
                args = { height = 200, log2_stride = 100 },
            },
            {
                message = "geometry exceeds uint256",
                args = { height = 256 },
            },
            {
                message = "geometry exceeds uint256",
                args = { height = 1, log2_stride = 255 },
            },
            {
                message = "cycle range exceeds uint256",
                args = {
                    height = 1,
                    base_cycle = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                },
            },
        }
        for _, row in ipairs(invalid) do
            Test.error_like(row.message, function()
                descriptor(row.args)
            end)
        end

        local maximum =
            "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Test.truthy(bint.eq(
            Domain.coordinate(maximum, 0).leaf_position,
            bint(maximum)
        ))
        for _, overflow in ipairs {
            "0x10000000000000000000000000000000000000000000000000000000000000000",
            "115792089237316195423570985008687907853269984665640564039457584007913129639936",
        } do
            Test.error_like("exceeds uint256", function()
                Domain.coordinate(overflow, 0)
            end)
            Test.error_like("exceeds uint256", function()
                Domain.timeout_one_wins(overflow)
            end)
        end
    end),

    Test.case("live match constructors reject impossible timeout shapes", function()
        local match = bisecting()
        local valid = Domain.live(match, Domain.timeout_two_wins(7))
        Test.equal(valid.timeout._tag, Domain.TimeoutDisposition.TWO_WINS)
        Test.truthy(bint.eq(valid.timeout.deferred_charge, bint(7)))

        local sealed = Domain.sealed_leaf(divergence())
        local awaiting = Domain.awaiting_child(divergence(), "child")
        local invalid = {
            {
                message = "winner cannot be the running responder",
                run = function()
                    Domain.live(match, Domain.timeout_one_wins(0))
                end,
            },
            {
                message = "sealed-leaf timeout winner cannot carry",
                run = function()
                    Domain.live(sealed, Domain.timeout_one_wins(1))
                end,
            },
            {
                message = "awaiting-child match cannot have",
                run = function()
                    Domain.live(awaiting, Domain.timeout_eliminate_both())
                end,
            },
        }
        for _, row in ipairs(invalid) do
            Test.error_like(row.message, row.run)
        end
    end),

    Test.case("descriptor validates phase kind, parity, position, and cycle", function()
        local leaf = descriptor()
        Domain.validate_live_in(
            Domain.live(bisecting(), Domain.timeout_none()),
            leaf
        )

        local invalid = {
            {
                message = "tournament kind",
                state = Domain.ready_to_delegate {
                    revealing_parent = "revealing",
                    waiting_children = Domain.waiting_children("left", "right"),
                    coordinate = coordinate(0),
                    responder = Domain.MatchSide.TWO,
                },
            },
            {
                message = "height parity",
                state = Domain.bisecting {
                    revealing_parent = "revealing",
                    waiting_children = Domain.waiting_children("left", "right"),
                    coordinate = coordinate(0),
                    remaining_height = 2,
                    responder = Domain.MatchSide.TWO,
                },
            },
            {
                message = "misaligned",
                state = Domain.bisecting {
                    revealing_parent = "revealing",
                    waiting_children = Domain.waiting_children("left", "right"),
                    coordinate = coordinate(1),
                    remaining_height = 2,
                    responder = Domain.MatchSide.ONE,
                },
            },
            {
                message = "descriptor geometry",
                state = Domain.sealed_leaf(Domain.divergence {
                    agree_state = "agree",
                    coordinate = Domain.coordinate(3, 4),
                    final_state_one = "one",
                    final_state_two = "two",
                }),
            },
        }
        for _, row in ipairs(invalid) do
            Test.error_like(row.message, function()
                Domain.validate_live_in(
                    Domain.live(row.state, Domain.timeout_none()),
                    leaf
                )
            end)
        end
    end),

    Test.case("recursive snapshot validates child provenance and geometry", function()
        local parent_descriptor = descriptor {
            kind = NON_LEAF,
        }
        local parent_match = Domain.match_id("one", "two")
        local parent_link =
            Domain.parent_link("root", parent_match, "one")
        local child_descriptor = descriptor {
            address = "child",
            level = 1,
            initial_hash = "agree",
            base_cycle = 3,
        }
        local child = Domain.snapshot {
            descriptor = child_descriptor,
            standing = Domain.matches_active(
                nil,
                Domain.JoinDisposition.OPEN
            ),
            local_commitment = "child-local",
            local_standing = Domain.not_joined(),
            parent = parent_link,
        }
        local awaiting = Domain.awaiting_child(divergence(), "child")
        local engagement = Domain.engagement(
            "one",
            parent_match,
            Domain.live(awaiting, Domain.timeout_none())
        )
        local parent = Domain.snapshot {
            descriptor = parent_descriptor,
            standing = Domain.matches_active(
                nil,
                Domain.JoinDisposition.CLOSED
            ),
            local_commitment = "one",
            local_standing = Domain.engaged(engagement),
            child = child,
        }
        Test.equal(parent.child.descriptor.address, "child")

        local wrong_descriptor = descriptor {
            address = "child",
            level = 1,
            initial_hash = "agree",
            base_cycle = 4,
        }
        local wrong_child = Domain.snapshot {
            descriptor = wrong_descriptor,
            standing = Domain.matches_active(
                nil,
                Domain.JoinDisposition.OPEN
            ),
            local_commitment = "child-local",
            local_standing = Domain.not_joined(),
            parent = parent_link,
        }
        Test.error_like("base cycle", function()
            Domain.snapshot {
                descriptor = parent_descriptor,
                standing = Domain.matches_active(
                    nil,
                    Domain.JoinDisposition.CLOSED
                ),
                local_commitment = "one",
                local_standing = Domain.engaged(engagement),
                child = wrong_child,
            }
        end)
    end),

    Test.case("snapshot rejects an engagement for another local commitment", function()
        local id = Domain.match_id("one", "two")
        local engagement = Domain.engagement(
            "one",
            id,
            Domain.live(bisecting(), Domain.timeout_none())
        )
        Test.error_like("engagement identity", function()
            Domain.snapshot {
                descriptor = descriptor(),
                standing = Domain.matches_active(
                    nil,
                    Domain.JoinDisposition.OPEN
                ),
                local_commitment = "two",
                local_standing = Domain.engaged(engagement),
            }
        end)

        local elimination = Domain.elimination_record(
            "one",
            id,
            Domain.EliminationReason.TIMEOUT,
            Domain.MatchSide.TWO
        )
        Test.error_like("elimination identity", function()
            Domain.snapshot {
                descriptor = descriptor(),
                standing = Domain.matches_active(
                    nil,
                    Domain.JoinDisposition.OPEN
                ),
                local_commitment = "two",
                local_standing = Domain.eliminated(elimination),
            }
        end)
    end),

    Test.case("planner observations own nested semantic constructor inputs", function()
        local tournament = descriptor()
        local standing = Domain.matches_active(
            nil,
            Domain.JoinDisposition.CLOSED
        )
        local id = Domain.match_id("one", "two")
        local state = bisecting()
        local engagement = Domain.engagement(
            "one",
            id,
            Domain.live(state, Domain.timeout_none())
        )
        local local_standing = Domain.engaged(engagement)
        local snapshot = Domain.snapshot {
            descriptor = tournament,
            standing = standing,
            local_commitment = "one",
            local_standing = local_standing,
        }

        tournament.address = "mutated-tournament"
        standing.joins = Domain.JoinDisposition.OPEN
        id.commitment_one = "mutated-commitment"
        state.responder = Domain.MatchSide.TWO
        state.coordinate.leaf_position[1] = 9
        local_standing.engagement.local_side = Domain.MatchSide.TWO

        Test.equal(snapshot.descriptor.address, "root")
        Test.equal(
            snapshot.standing.joins,
            Domain.JoinDisposition.CLOSED
        )
        Test.equal(
            snapshot.local_standing.engagement.match_id.commitment_one,
            "one"
        )
        Test.equal(
            snapshot.local_standing.engagement.live.state.responder,
            Domain.MatchSide.ONE
        )
        Test.truthy(bint.iszero(
            snapshot.local_standing.engagement.live.state
                .coordinate.leaf_position
        ))
        Test.equal(
            snapshot.local_standing.engagement.local_side,
            Domain.MatchSide.ONE
        )

        local observed_id = Domain.match_id("one", "two")
        local observed_state = bisecting()
        local observed = Domain.observed_match(
            "one:two",
            observed_id,
            Domain.live(observed_state, Domain.timeout_none())
        )
        local observed_descriptor = descriptor()
        local observed_standing = Domain.matches_active(
            nil,
            Domain.JoinDisposition.CLOSED
        )
        local observation = Domain.tournament_observation(
            observed_descriptor,
            observed_standing,
            { observed }
        )

        observed_descriptor.address = "mutated-tournament"
        observed_standing.joins = Domain.JoinDisposition.OPEN
        observed_id.commitment_one = "mutated-commitment"
        observed_state.responder = Domain.MatchSide.TWO

        Test.equal(observation.descriptor.address, "root")
        Test.equal(
            observation.standing.joins,
            Domain.JoinDisposition.CLOSED
        )
        Test.equal(
            observation.matches["one:two"].id.commitment_one,
            "one"
        )
        Test.equal(
            observation.matches["one:two"].live.state.responder,
            Domain.MatchSide.ONE
        )
        Test.truthy(
            observation.matches["one:two"] == observation.match_order[1],
            "observation lookup and order must share one owned record"
        )
    end),
}
