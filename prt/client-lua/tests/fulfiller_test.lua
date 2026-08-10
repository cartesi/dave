local Context = require "player.context"
local Domain = require "player.domain"
local Fold = require "player.fold"
local Fulfiller = require "player.fulfiller"
local Hash = require "cryptography.hash"
local MerkleBuilder = require "cryptography.merkle_builder"
local Planner = require "player.planner"
local Test = require "tests.testlib"

local LEAF = Domain.TournamentKind.LEAF
local NON_LEAF = Domain.TournamentKind.NON_LEAF

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
    local leaves = {}
    for offset = 0, (1 << height) - 1 do
        local leaf = digest(first_leaf + offset)
        leaves[offset + 1] = leaf
        builder:add(leaf)
    end
    return builder:build(initial_hash), leaves
end

local function descriptor(at, initial, level, kind)
    return Domain.descriptor {
        address = at,
        level = level,
        kind = kind,
        initial_hash = initial,
        base_cycle = 0,
        log2_stride = 0,
        height = 2,
    }
end

local function engaged_context(args)
    local root = address(1)
    local initial = digest(1)
    local local_tree, leaves = tree(initial, 10, 2)
    local opponent = digest(30)
    local one = args.side == Domain.MatchSide.ONE
        and local_tree.root_hash
        or opponent
    local two = args.side == Domain.MatchSide.TWO
        and local_tree.root_hash
        or opponent
    local fold = Fold.new(root)
    for _, commitment in ipairs { one, two } do
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
            one,
            two,
            digest(32),
            one:join(two),
            100
        )
    ))
    local match = fold:live_matches(root)[1]
    local desc = descriptor(
        root,
        initial,
        0,
        args.non_leaf and NON_LEAF or LEAF
    )
    local live = Domain.live(args.state, args.timeout or Domain.timeout_none())
    local observation = Domain.tournament_observation(
        desc,
        Domain.matches_active(nil, Domain.JoinDisposition.OPEN),
        { Domain.observed_match(match.id_hash, match.id, live) }
    )
    local context = Context.assemble {
        fold = fold,
        observations = { [root] = observation },
        commitment_builder = {
            build = function()
                return local_tree
            end,
        },
    }
    return context, local_tree, leaves, match
end

local function plan_action(context, expected)
    local decision = Planner.plan(context.snapshot)
    Test.equal(decision._tag, Domain.HeroDecision.ACT)
    Test.equal(decision.intent._tag, expected)
    return decision.intent
end

return {
    Test.case("join fulfillment derives the exact last proof and root opening", function()
        local root = address(1)
        local initial = digest(1)
        local local_tree, leaves = tree(initial, 10, 2)
        local desc = descriptor(root, initial, 0, LEAF)
        local context = Context.assemble {
            fold = Fold.new(root),
            observations = {
                [root] = Domain.tournament_observation(
                    desc,
                    Domain.awaiting_closure(nil),
                    {}
                ),
            },
            commitment_builder = {
                build = function()
                    return local_tree
                end,
            },
        }
        local intent = plan_action(context, Domain.HeroIntent.JOIN)
        local action = Fulfiller.prepare(intent, context)
        local _, left, right = local_tree:children()
        Test.equal(action._tag, Fulfiller.PreparedAction.JOIN)
        Test.equal(action.tournament, root)
        Test.equal(action.final_state, leaves[4])
        Test.equal(action.left, left)
        Test.equal(action.right, right)
        Test.equal(#action.proof, 2)
    end),

    Test.case("advance fulfillment opens the selected local branch", function()
        local initial = digest(1)
        local local_tree = tree(initial, 10, 2)
        local state = Domain.bisecting {
            revealing_parent = local_tree.root_hash,
            waiting_children =
                Domain.waiting_children(digest(50), digest(51)),
            coordinate = Domain.coordinate(0, 0),
            remaining_height = 2,
            responder = Domain.MatchSide.ONE,
        }
        local context, retained, leaves, match = engaged_context {
            side = Domain.MatchSide.ONE,
            state = state,
        }
        local intent = plan_action(context, Domain.HeroIntent.ADVANCE)
        local action = Fulfiller.prepare(intent, context)
        local _, left, right = retained:children()
        Test.equal(action.match_id.commitment_one, match.id.commitment_one)
        Test.equal(action.left, left)
        Test.equal(action.right, right)
        Test.equal(action.new_left, leaves[1])
        Test.equal(action.new_right, leaves[2])
    end),

    Test.case("seal and child fulfillment distinguish typed ready variants", function()
        for _, fixture in ipairs {
            {
                non_leaf = false,
                tag = Domain.LiveMatchState.READY_TO_SEAL_LEAF,
                intent = Domain.HeroIntent.SEAL_LEAF,
                prepared = Fulfiller.PreparedAction.SEAL_LEAF,
            },
            {
                non_leaf = true,
                tag = Domain.LiveMatchState.READY_TO_DELEGATE,
                intent = Domain.HeroIntent.CREATE_CHILD,
                prepared = Fulfiller.PreparedAction.CREATE_CHILD,
            },
        } do
            local initial = digest(1)
            local local_tree = tree(initial, 10, 2)
            local _, local_left = local_tree:children()
            local fields = {
                revealing_parent = local_left,
                waiting_children =
                    Domain.waiting_children(digest(50), digest(51)),
                coordinate = Domain.coordinate(0, 0),
                responder = Domain.MatchSide.TWO,
            }
            local state = fixture.tag
                    == Domain.LiveMatchState.READY_TO_SEAL_LEAF
                and Domain.ready_to_seal_leaf(fields)
                or Domain.ready_to_delegate(fields)
            local context, retained, leaves = engaged_context {
                side = Domain.MatchSide.TWO,
                state = state,
                non_leaf = fixture.non_leaf,
            }
            local intent = plan_action(context, fixture.intent)
            local action = Fulfiller.prepare(intent, context)
            Test.equal(action._tag, fixture.prepared)
            Test.equal(action.left, leaves[1])
            Test.equal(action.right, leaves[2])
            Test.equal(action.agree_state, retained.implicit_hash)
            Test.equal(#action.proof, 0)
        end
    end),

    Test.case("timeout and leaf proof fulfillment use authoritative semantics", function()
        local divergence = Domain.divergence {
            agree_state = digest(60),
            coordinate = Domain.coordinate(1, 1),
            final_state_one = digest(61),
            final_state_two = digest(62),
        }
        local sealed = Domain.sealed_leaf(divergence)
        local timeout_context, retained = engaged_context {
            side = Domain.MatchSide.ONE,
            state = sealed,
            timeout = Domain.timeout_one_wins(0),
        }
        local timeout_intent =
            plan_action(timeout_context, Domain.HeroIntent.CLAIM_TIMEOUT)
        local timeout_action =
            Fulfiller.prepare(timeout_intent, timeout_context)
        local _, left, right = retained:children()
        Test.equal(timeout_action.left, left)
        Test.equal(timeout_action.right, right)

        local proof_context = engaged_context {
            side = Domain.MatchSide.ONE,
            state = sealed,
        }
        local proof_intent =
            plan_action(proof_context, Domain.HeroIntent.PROVE_LEAF)
        local calls = {}
        local proof_action = Fulfiller.prepare(
            proof_intent,
            proof_context,
            {
                machine_logs = function(agree_state, cycle)
                    table.insert(calls, {
                        agree_state = agree_state,
                        cycle = cycle,
                    })
                    return "0xproof", divergence.final_state_one
                end,
            }
        )
        Test.equal(#calls, 1)
        Test.equal(calls[1].agree_state, divergence.agree_state)
        Test.equal(tostring(calls[1].cycle), "1")
        Test.equal(proof_action.proof, "0xproof")

        local wrong_post_state = function()
            return "0xproof", divergence.final_state_two
        end
        Test.error_like("local final state", function()
            Fulfiller.prepare(proof_intent, proof_context, {
                machine_logs = wrong_post_state,
            })
        end)
        local adversarial_action = Fulfiller.prepare(
            proof_intent,
            proof_context,
            {
                machine_logs = wrong_post_state,
                allow_invalid_claims = true,
            }
        )
        Test.equal(adversarial_action.proof, "0xproof")
    end),

    Test.case("propagation fulfillment opens the parent commitment", function()
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
                root_tree.root_hash:join(opponent),
                100
            )
        ))
        local match = fold:live_matches(root)[1]
        fold:apply(Fold.event(
            root,
            3,
            Fold.Event.new_inner_tournament(match.id_hash, child)
        ))
        fold:apply(Fold.event(
            child,
            4,
            Fold.Event.commitment_joined(
                child_tree.root_hash,
                digest(40)
            )
        ))
        local divergence = Domain.divergence {
            agree_state = child_initial,
            coordinate = Domain.coordinate(0, 0),
            final_state_one = digest(40),
            final_state_two = digest(41),
        }
        local context = Context.assemble {
            fold = fold,
            observations = {
                [root] = Domain.tournament_observation(
                    descriptor(root, root_initial, 0, NON_LEAF),
                    Domain.matches_active(
                        nil,
                        Domain.JoinDisposition.OPEN
                    ),
                    {
                        Domain.observed_match(
                            match.id_hash,
                            match.id,
                            Domain.live(
                                Domain.awaiting_child(
                                    divergence,
                                    child
                                ),
                                Domain.timeout_none()
                            )
                        ),
                    }
                ),
                [child] = Domain.tournament_observation(
                    descriptor(child, child_initial, 1, LEAF),
                    Domain.inner_winner(
                        root_tree.root_hash,
                        child_tree.root_hash
                    ),
                    {}
                ),
            },
            commitment_builder = {
                build = function(_, _, level)
                    return level == 0 and root_tree or child_tree
                end,
            },
        }
        local intent =
            plan_action(context, Domain.HeroIntent.PROPAGATE_CHILD)
        local action = Fulfiller.prepare(intent, context)
        local _, left, right = root_tree:children()
        Test.equal(action.parent_tournament, root)
        Test.equal(action.child_tournament, child)
        Test.equal(action.left, left)
        Test.equal(action.right, right)
    end),
}
