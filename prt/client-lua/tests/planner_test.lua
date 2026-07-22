local bint = require "utils.bint" (256)
local Domain = require "player.domain"
local Planner = require "player.planner"
local Test = require "tests.testlib"

local function descriptor(levels, address, level, initial_hash, base_cycle)
    return Domain.descriptor {
        address = address or "root",
        level = level or 0,
        levels = levels or 1,
        initial_hash = initial_hash or "initial",
        base_cycle = base_cycle or 0,
        log2_stride = 0,
        height = 4,
    }
end

local function match_id()
    return Domain.match_id("one", "two")
end

local function coordinate(position)
    return Domain.coordinate(position, position)
end

local function unresolved_args(responder)
    return {
        revealing_parent = "revealing",
        waiting_children = Domain.waiting_children("left", "right"),
        coordinate = coordinate(0),
        responder = responder,
    }
end

local function bisecting()
    local args = unresolved_args(Domain.MatchSide.ONE)
    args.remaining_height = 2
    return Domain.bisecting(args)
end

local function ready_leaf()
    return Domain.ready_to_seal_leaf(
        unresolved_args(Domain.MatchSide.TWO)
    )
end

local function ready_child()
    return Domain.ready_to_delegate(
        unresolved_args(Domain.MatchSide.TWO)
    )
end

local function divergence()
    return Domain.divergence {
        agree_state = "agree",
        coordinate = coordinate(3),
        final_state_one = "final-one",
        final_state_two = "final-two",
    }
end

local function live_snapshot(state, timeout, local_side, levels)
    local id = match_id()
    local local_commitment =
        Domain.side_commitment(local_side, id)
    local engagement = Domain.engagement(
        local_commitment,
        id,
        Domain.live(state, timeout)
    )
    return Domain.snapshot {
        descriptor = descriptor(levels),
        standing = Domain.matches_active(
            "dangling",
            Domain.JoinDisposition.CLOSED
        ),
        local_commitment = local_commitment,
        local_standing = Domain.engaged(engagement),
    }
end

local function root_snapshot(standing, local_commitment, local_standing)
    return Domain.snapshot {
        descriptor = descriptor(1),
        standing = standing,
        local_commitment = local_commitment,
        local_standing = local_standing,
    }
end

return {
    Test.case("terminal results, joins, candidates, and elimination are explicit", function()
        local rows = {
            {
                name = "won",
                snapshot = root_snapshot(
                    Domain.root_winner("ours", "final"),
                    "ours",
                    Domain.candidate()
                ),
                decision = Domain.HeroDecision.TERMINAL,
                detail = Domain.HeroTerminal.WON,
            },
            {
                name = "lost result",
                snapshot = root_snapshot(
                    Domain.root_winner("other", "final"),
                    "ours",
                    Domain.not_joined()
                ),
                decision = Domain.HeroDecision.TERMINAL,
                detail = Domain.HeroTerminal.LOST,
            },
            {
                name = "failed root",
                snapshot = root_snapshot(
                    Domain.root_failed(),
                    "ours",
                    Domain.not_joined()
                ),
                decision = Domain.HeroDecision.TERMINAL,
                detail = Domain.HeroTerminal.FAILED_NO_WINNER,
            },
            {
                name = "join",
                snapshot = root_snapshot(
                    Domain.matches_active(
                        nil,
                        Domain.JoinDisposition.OPEN
                    ),
                    "ours",
                    Domain.not_joined()
                ),
                decision = Domain.HeroDecision.ACT,
                detail = Domain.HeroIntent.JOIN,
            },
            {
                name = "joins closed",
                snapshot = root_snapshot(
                    Domain.matches_active(
                        nil,
                        Domain.JoinDisposition.CLOSED
                    ),
                    "ours",
                    Domain.not_joined()
                ),
                decision = Domain.HeroDecision.WAIT,
                detail = Domain.WaitReason.JOINS_CLOSED,
            },
            {
                name = "candidate blocked",
                snapshot = root_snapshot(
                    Domain.matches_active(
                        "ours",
                        Domain.JoinDisposition.OPEN
                    ),
                    "ours",
                    Domain.candidate()
                ),
                decision = Domain.HeroDecision.WAIT,
                detail = Domain.WaitReason.CANDIDATE_BLOCKED_BY_MATCHES,
            },
            {
                name = "awaiting closure",
                snapshot = root_snapshot(
                    Domain.awaiting_closure("ours"),
                    "ours",
                    Domain.candidate()
                ),
                decision = Domain.HeroDecision.WAIT,
                detail = Domain.WaitReason.AWAITING_TOURNAMENT_CLOSURE,
            },
        }

        for _, row in ipairs(rows) do
            local decision = Planner.plan(row.snapshot)
            Test.equal(decision._tag, row.decision, row.name)
            local detail = decision.result or decision.reason
                or decision.intent._tag
            Test.equal(detail, row.detail, row.name)
        end

        local record = Domain.elimination_record(
            "one",
            match_id(),
            Domain.EliminationReason.STEP,
            Domain.MatchSide.TWO
        )
        local eliminated = root_snapshot(
            Domain.matches_active(
                "other",
                Domain.JoinDisposition.CLOSED
            ),
            "one",
            Domain.eliminated(record)
        )
        local decision = Planner.plan(eliminated)
        Test.equal(decision._tag, Domain.HeroDecision.TERMINAL)
        Test.equal(decision.result, Domain.HeroTerminal.LOST)
    end),

    Test.case("no-timeout phase table chooses one action or wait", function()
        local rows = {
            {
                state = bisecting(),
                side = Domain.MatchSide.ONE,
                levels = 1,
                expected = Domain.HeroIntent.ADVANCE,
            },
            {
                state = bisecting(),
                side = Domain.MatchSide.TWO,
                levels = 1,
                expected = Domain.WaitReason.OPPONENT_TURN,
            },
            {
                state = ready_leaf(),
                side = Domain.MatchSide.TWO,
                levels = 1,
                expected = Domain.HeroIntent.SEAL_LEAF,
            },
            {
                state = ready_leaf(),
                side = Domain.MatchSide.ONE,
                levels = 1,
                expected = Domain.WaitReason.OPPONENT_TURN,
            },
            {
                state = ready_child(),
                side = Domain.MatchSide.TWO,
                levels = 2,
                expected = Domain.HeroIntent.CREATE_CHILD,
            },
            {
                state = ready_child(),
                side = Domain.MatchSide.ONE,
                levels = 2,
                expected = Domain.WaitReason.OPPONENT_TURN,
            },
            {
                state = Domain.sealed_leaf(divergence()),
                side = Domain.MatchSide.ONE,
                levels = 1,
                expected = Domain.HeroIntent.PROVE_LEAF,
            },
            {
                state = Domain.sealed_leaf(divergence()),
                side = Domain.MatchSide.TWO,
                levels = 1,
                expected = Domain.HeroIntent.PROVE_LEAF,
            },
        }
        for _, row in ipairs(rows) do
            local decision = Planner.plan(live_snapshot(
                row.state,
                Domain.timeout_none(),
                row.side,
                row.levels
            ))
            local actual = decision.intent
                and decision.intent._tag
                or decision.reason
            Test.equal(actual, row.expected)
        end
    end),

    Test.case("planned match payload is owned independently of the snapshot", function()
        local snapshot = live_snapshot(
            bisecting(),
            Domain.timeout_none(),
            Domain.MatchSide.ONE,
            1
        )
        local decision = Planner.plan(snapshot)
        local intent = decision.intent
        Test.equal(intent._tag, Domain.HeroIntent.ADVANCE)

        intent.match_id.commitment_one = "mutated"
        intent.match_state.responder = Domain.MatchSide.TWO
        Test.equal(
            snapshot.local_standing.engagement.match_id.commitment_one,
            "one"
        )
        Test.equal(
            snapshot.local_standing.engagement.live.state.responder,
            Domain.MatchSide.ONE
        )
    end),

    Test.case("phase planners return exact typed match payloads", function()
        local rows = {
            {
                state = bisecting(),
                side = Domain.MatchSide.ONE,
                levels = 1,
                intent = Domain.HeroIntent.ADVANCE,
                state_tag = Domain.LiveMatchState.BISECTING,
            },
            {
                state = ready_leaf(),
                side = Domain.MatchSide.TWO,
                levels = 1,
                intent = Domain.HeroIntent.SEAL_LEAF,
                state_tag = Domain.LiveMatchState.READY_TO_SEAL_LEAF,
            },
            {
                state = ready_child(),
                side = Domain.MatchSide.TWO,
                levels = 2,
                intent = Domain.HeroIntent.CREATE_CHILD,
                state_tag = Domain.LiveMatchState.READY_TO_DELEGATE,
            },
            {
                state = Domain.sealed_leaf(divergence()),
                side = Domain.MatchSide.ONE,
                levels = 1,
                intent = Domain.HeroIntent.PROVE_LEAF,
                state_tag = Domain.LiveMatchState.SEALED_LEAF,
            },
        }

        for _, row in ipairs(rows) do
            local action = Planner.plan(live_snapshot(
                row.state,
                Domain.timeout_none(),
                row.side,
                row.levels
            )).intent
            Test.equal(action._tag, row.intent)
            Test.equal(action.tournament, "root")
            Test.equal(action.match_id.commitment_one, "one")
            Test.equal(action.match_id.commitment_two, "two")
            Test.equal(
                action.commitment,
                Domain.side_commitment(row.side, action.match_id)
            )
            Test.equal(action.side, row.side)
            Test.equal(action.match_state._tag, row.state_tag)

            if row.state_tag == Domain.LiveMatchState.SEALED_LEAF then
                Test.equal(
                    action.match_state.divergence.agree_state,
                    "agree"
                )
                Test.truthy(bint.eq(
                    action.match_state.divergence.coordinate.leaf_position,
                    bint(3)
                ))
            else
                Test.equal(action.match_state.revealing_parent, "revealing")
                Test.equal(action.match_state.waiting_children.left, "left")
                Test.equal(action.match_state.waiting_children.right, "right")
                Test.truthy(bint.iszero(
                    action.match_state.coordinate.leaf_position
                ))
            end
        end

        local timeout = Planner.plan(live_snapshot(
            bisecting(),
            Domain.timeout_two_wins(7),
            Domain.MatchSide.TWO,
            1
        )).intent
        Test.equal(timeout._tag, Domain.HeroIntent.CLAIM_TIMEOUT)
        Test.equal(timeout.tournament, "root")
        Test.equal(timeout.match_id.commitment_one, "one")
        Test.equal(timeout.match_id.commitment_two, "two")
        Test.equal(timeout.commitment, "two")
        Test.equal(timeout.survivor, Domain.MatchSide.TWO)
        Test.truthy(bint.eq(timeout.deferred_charge, bint(7)))
    end),

    Test.case("intent constructors reject impossible variant and identity shapes", function()
        local function locator(state, commitment, side)
            return {
                tournament = "root",
                match_id = match_id(),
                commitment = commitment or "one",
                side = side or Domain.MatchSide.ONE,
                match_state = state,
            }
        end

        local wrong_variants = {
            function()
                Domain.advance_intent(locator(ready_leaf()))
            end,
            function()
                Domain.seal_intent(locator(ready_child()))
            end,
            function()
                Domain.child_intent(locator(ready_leaf()))
            end,
            function()
                Domain.proof_intent(locator(bisecting()))
            end,
        }
        for _, run in ipairs(wrong_variants) do
            Test.error_like("wrong live-state variant", run)
        end

        Test.error_like("commitment disagrees with its match side", function()
            Domain.advance_intent(locator(
                bisecting(),
                "two",
                Domain.MatchSide.ONE
            ))
        end)
        Test.error_like("surviving side", function()
            Domain.timeout_intent {
                tournament = "root",
                match_id = match_id(),
                commitment = "one",
                survivor = Domain.MatchSide.TWO,
                deferred_charge = 0,
            }
        end)
        Test.error_like("parent commitment disagrees", function()
            Domain.propagation_intent {
                parent_tournament = "root",
                child_tournament = "child",
                parent_match = match_id(),
                parent_commitment = "one",
                parent_side = Domain.MatchSide.TWO,
                child_winner = "child-winner",
            }
        end)
    end),

    Test.case("authoritative timeout disposition outranks phase actions", function()
        local phases = {
            {
                state = bisecting(),
                levels = 1,
                winner = Domain.MatchSide.TWO,
                timeout = function()
                    return Domain.timeout_two_wins(7)
                end,
            },
            {
                state = ready_leaf(),
                levels = 1,
                winner = Domain.MatchSide.ONE,
                timeout = function()
                    return Domain.timeout_one_wins(7)
                end,
            },
            {
                state = ready_child(),
                levels = 2,
                winner = Domain.MatchSide.ONE,
                timeout = function()
                    return Domain.timeout_one_wins(7)
                end,
            },
            {
                state = Domain.sealed_leaf(divergence()),
                levels = 1,
                winner = Domain.MatchSide.ONE,
                timeout = function()
                    return Domain.timeout_one_wins(0)
                end,
            },
        }
        for _, phase in ipairs(phases) do
            local opponent = phase.winner == Domain.MatchSide.ONE
                and Domain.MatchSide.TWO
                or Domain.MatchSide.ONE
            local ours = Planner.plan(live_snapshot(
                phase.state,
                phase.timeout(),
                phase.winner,
                phase.levels
            ))
            Test.equal(ours.intent._tag, Domain.HeroIntent.CLAIM_TIMEOUT)

            local theirs = Planner.plan(live_snapshot(
                phase.state,
                phase.timeout(),
                opponent,
                phase.levels
            ))
            Test.equal(
                theirs.reason,
                Domain.WaitReason.OPPONENT_WINS_BY_TIMEOUT
            )

            local eliminate = Planner.plan(live_snapshot(
                phase.state,
                Domain.timeout_eliminate_both(),
                phase.winner,
                phase.levels
            ))
            Test.equal(eliminate.reason, Domain.WaitReason.MATCH_ELIMINABLE)
        end
    end),

    Test.case("awaiting child returns exactly the child decision", function()
        local parent_descriptor = descriptor(2)
        local id = match_id()
        local parent_link = Domain.parent_link("root", id, "one")
        local child = Domain.snapshot {
            descriptor = descriptor(2, "child", 1, "agree", 3),
            standing = Domain.matches_active(
                nil,
                Domain.JoinDisposition.OPEN
            ),
            local_commitment = "child-local",
            local_standing = Domain.not_joined(),
            parent = parent_link,
        }
        local engagement = Domain.engagement(
            "one",
            id,
            Domain.live(
                Domain.awaiting_child(divergence(), "child"),
                Domain.timeout_none()
            )
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

        local decision = Planner.plan(parent)
        Test.equal(decision._tag, Domain.HeroDecision.ACT)
        Test.equal(decision.intent._tag, Domain.HeroIntent.JOIN)
        Test.equal(decision.intent.tournament, "child")
        Test.equal(decision.intent.commitment, "child-local")
        Test.equal(Planner.plan(parent).intent._tag, Domain.HeroIntent.JOIN)
    end),

    Test.case("inner result propagation and elimination stay distinct", function()
        local id = match_id()
        local parent = Domain.parent_link("root", id, "one")
        local child_descriptor = descriptor(2, "child", 1, "agree", 3)
        local winner = Domain.snapshot {
            descriptor = child_descriptor,
            standing = Domain.inner_winner("one", "child-local"),
            local_commitment = "child-local",
            local_standing = Domain.candidate(),
            parent = parent,
        }
        local propagation = Planner.plan(winner)
        Test.equal(propagation.intent._tag, Domain.HeroIntent.PROPAGATE_CHILD)
        Test.equal(propagation.intent.parent_tournament, "root")
        Test.equal(propagation.intent.child_tournament, "child")
        Test.equal(propagation.intent.parent_match.commitment_one, "one")
        Test.equal(propagation.intent.parent_match.commitment_two, "two")
        Test.equal(propagation.intent.parent_commitment, "one")
        Test.equal(propagation.intent.parent_side, Domain.MatchSide.ONE)
        Test.equal(propagation.intent.child_winner, "child-local")

        local lost = Domain.snapshot {
            descriptor = child_descriptor,
            standing = Domain.inner_winner("two", "other-child"),
            local_commitment = "child-local",
            local_standing = Domain.not_joined(),
            parent = parent,
        }
        Test.equal(
            Planner.plan(lost).result,
            Domain.HeroTerminal.LOST
        )

        local eliminable_rows = {
            {
                standing = Domain.inner_eliminable_no_candidate(),
                local_commitment = "child-local",
                local_standing = Domain.not_joined(),
            },
            {
                standing =
                    Domain.inner_eliminable_winner_expired("expired"),
                local_commitment = "expired",
                local_standing = Domain.candidate(),
            },
        }
        for _, row in ipairs(eliminable_rows) do
            local eliminable = Domain.snapshot {
                descriptor = child_descriptor,
                standing = row.standing,
                local_commitment = row.local_commitment,
                local_standing = row.local_standing,
                parent = parent,
            }
            local waiting = Planner.plan(eliminable)
            Test.equal(waiting._tag, Domain.HeroDecision.WAIT)
            Test.equal(waiting.reason, Domain.WaitReason.CHILD_ELIMINABLE)
        end
    end),
}
