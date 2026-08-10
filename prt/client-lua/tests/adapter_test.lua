local Adapter = require "player.adapter"
local Domain = require "player.domain"
local Fold = require "player.fold"
local Reader = require "player.reader"
local Hash = require "cryptography.hash"
local Test = require "tests.testlib"

local function digest(byte)
    return Hash:from_digest_hex(
        "0x" .. string.rep(string.format("%02x", byte), 32)
    )
end

local function address(byte)
    return "0x" .. string.rep(string.format("%02x", byte), 20)
end

local function head()
    return {
        number = 12,
        hash = digest(240):hex_string(),
        parent_hash = digest(239):hex_string(),
    }
end

local function descriptor(fields)
    fields = fields or {}
    return {
        initial_hash = fields.initial_hash or digest(1),
        base_cycle = fields.base_cycle or 0,
        log2_stride = fields.log2_stride or 0,
        height = fields.height or 4,
        level = fields.level or 0,
        kind = fields.kind or 0,
    }
end

local function standing(tag, fields)
    fields = fields or {}
    return {
        standing = tag,
        accepts_joins = fields.accepts_joins or false,
        has_candidate = fields.has_candidate or false,
        candidate = fields.candidate or Hash.zero,
        final_state = fields.final_state or Hash.zero,
        parent_commitment = fields.parent_commitment or Hash.zero,
    }
end

local function timeout(phase, outcome, charge)
    return {
        actual_phase = phase,
        outcome = outcome or 0,
        deferred_charge = charge or 0,
    }
end

local function bisecting(phase, fields)
    fields = fields or {}
    return {
        actual_phase = phase,
        revealing_parent = fields.revealing_parent or digest(10),
        waiting_left = fields.waiting_left or digest(11),
        waiting_right = fields.waiting_right or digest(12),
        segment_start_position = fields.position or 0,
        segment_start_cycle = fields.cycle or 0,
        current_height = fields.height or 4,
        responder = fields.responder or 0,
    }
end

local function ready(phase, fields)
    fields = fields or {}
    return {
        actual_phase = phase,
        revealing_parent = fields.revealing_parent or digest(10),
        waiting_left = fields.waiting_left or digest(11),
        waiting_right = fields.waiting_right or digest(12),
        segment_start_position = fields.position or 0,
        segment_start_cycle = fields.cycle or 0,
        responder = fields.responder == nil and 1 or fields.responder,
    }
end

local function sealed(phase, fields)
    fields = fields or {}
    return {
        actual_phase = phase,
        agree_state = fields.agree_state or digest(20),
        divergence_position = fields.position or 3,
        divergence_cycle = fields.cycle or 3,
        final_state_one = fields.final_state_one or digest(21),
        final_state_two = fields.final_state_two or digest(22),
    }
end

local function mock_transport(responses, calls)
    calls = calls or {}
    return {
        observer_call = function(_, at, view, argument, observation_head)
            table.insert(calls, {
                address = at,
                view = view,
                argument = argument,
                head = observation_head,
            })
            local response = assert(responses[at], "unexpected tournament")
            local value = assert(response[view.name], "unexpected observer view")
            if type(value) == "function" then
                return value(argument)
            end
            return value
        end,
    }, calls
end

local function apply_advances(
    fold,
    tournament,
    match,
    count,
    final_other_parent,
    final_left_node
)
    for index = 1, count do
        fold:apply(Fold.event(
            tournament,
            2 + index,
            Fold.Event.match_advanced(
                match.id_hash,
                index == count and final_other_parent or digest(50 + index),
                index == count and final_left_node or digest(60 + index),
                100 + index
            )
        ))
    end
end

local function live_fold(root, child)
    local one = digest(30)
    local two = digest(31)
    local fold = Fold.new(root)
    fold:apply(Fold.event(
        root,
        1,
        Fold.Event.commitment_joined(one, digest(40))
    ))
    fold:apply(Fold.event(
        root,
        1,
        Fold.Event.commitment_joined(two, digest(41))
    ))
    fold:apply(Fold.event(
        root,
        2,
        Fold.Event.match_created(
            one,
            two,
            digest(42),
            one:join(two),
            100
        )
    ))
    local match = fold:live_matches(root)[1]
    if child then
        apply_advances(fold, root, match, 3, digest(10), digest(11))
        fold:apply(Fold.event(
            root,
            6,
            Fold.Event.new_inner_tournament(match.id_hash, child)
        ))
    end
    return fold, match, one, two
end

local function live_responses(root, descriptor_wire, phase, projection)
    local responses = {
        [root] = {
            tournamentDescriptor = descriptor_wire,
            tournamentStanding = standing(0),
            classifyMatchTimeout = timeout(phase),
        },
    }
    if phase == 1 then
        responses[root].bisectingMatch = projection
    elseif phase == 2 then
        responses[root].readyToSealMatch = projection
    else
        responses[root].sealedMatch = projection
    end
    return responses
end

local function uint_word(value)
    return string.format("%064x", value)
end

local function hash_word(value)
    return value:hex_string():sub(3)
end

local function encoded(words)
    return "0x" .. table.concat(words)
end

return {
    Test.case("static ABI decoder preserves hashes, booleans, and integers", function()
        Test.equal(Adapter.View.TIMEOUT.name, "classifyMatchTimeout")
        Test.equal(
            Adapter.View.TIMEOUT.signature,
            "classifyMatchTimeout((bytes32,bytes32))"
        )
        local standing_wire = Adapter.decode_result(
            Adapter.View.STANDING,
            encoded {
                uint_word(2),
                uint_word(0),
                uint_word(1),
                hash_word(digest(2)),
                hash_word(digest(3)),
                hash_word(Hash.zero),
            }
        )
        Test.equal(standing_wire.standing, 2)
        Test.equal(standing_wire.accepts_joins, false)
        Test.equal(standing_wire.has_candidate, true)
        Test.truthy(Hash:is_of_type_hash(standing_wire.candidate))
        Test.equal(standing_wire.final_state, digest(3))

        local timeout_wire = Adapter.decode_result(
            Adapter.View.TIMEOUT,
            encoded {
                uint_word(1),
                uint_word(2),
                uint_word(7),
            }
        )
        Test.equal(timeout_wire.actual_phase, 1)
        Test.equal(timeout_wire.outcome, 2)
        Test.truthy(timeout_wire.deferred_charge:match("7$"))

        local projection_shapes = {
            {
                view = Adapter.View.BISECTING,
                words = {
                    uint_word(1),
                    hash_word(digest(4)),
                    hash_word(digest(5)),
                    hash_word(digest(6)),
                    uint_word(8),
                    uint_word(9),
                    uint_word(3),
                    uint_word(1),
                },
                field = "current_height",
                expected = 3,
            },
            {
                view = Adapter.View.READY,
                words = {
                    uint_word(2),
                    hash_word(digest(4)),
                    hash_word(digest(5)),
                    hash_word(digest(6)),
                    uint_word(8),
                    uint_word(9),
                    uint_word(1),
                },
                field = "responder",
                expected = 1,
            },
            {
                view = Adapter.View.SEALED,
                words = {
                    uint_word(3),
                    hash_word(digest(4)),
                    uint_word(8),
                    uint_word(9),
                    hash_word(digest(5)),
                    hash_word(digest(6)),
                },
                field = "final_state_two",
                expected = digest(6),
            },
        }
        for _, shape in ipairs(projection_shapes) do
            local wire = Adapter.decode_result(
                shape.view,
                encoded(shape.words)
            )
            Test.equal(wire[shape.field], shape.expected)
        end

        Test.error_like("canonical ABI boolean", function()
            Adapter.decode_result(
                Adapter.View.STANDING,
                encoded {
                    uint_word(0),
                    uint_word(2),
                    uint_word(0),
                    hash_word(Hash.zero),
                    hash_word(Hash.zero),
                    hash_word(Hash.zero),
                }
            )
        end)
    end),

    Test.case("compatibility reader decodes authoritative kind", function()
        local reader = Reader:new("unused")
        function reader._call(_reader, _address, signature, arguments)
            Test.equal(
                signature,
                "tournamentDescriptor()"
                    .. "((bytes32,uint256,uint64,uint64,uint64,uint8))"
            )
            Test.equal(#arguments, 0)
            return {
                "(0x" .. string.rep("01", 32) .. ",3,44,48,2,1)",
            }
        end

        local constants = reader:read_constants(address(1))
        Test.equal(constants.level, 2)
        Test.equal(constants.kind, 1)
        Test.equal(constants.log2_stride, 44)
        Test.equal(constants.height, 48)

        function reader._call()
            return {
                "(0x" .. string.rep("01", 32) .. ",3,44,48,2,9)",
            }
        end
        Test.error_like("unknown tournament kind", function()
            reader:read_constants(address(1))
        end)
    end),

    Test.case("ABI descriptor rejects height or extent 256", function()
        local root = address(1)
        local base_words = {
            hash_word(digest(1)),
            uint_word(0),
            uint_word(254),
            uint_word(1),
            uint_word(0),
            uint_word(0),
        }
        local accepted_wire = Adapter.decode_result(
            Adapter.View.DESCRIPTOR,
            encoded(base_words)
        )
        local responses = {
            [root] = {
                tournamentDescriptor = accepted_wire,
                tournamentStanding = standing(3),
            },
        }
        local transport = mock_transport(responses)
        local observations =
            Adapter.observe_fold(transport, Fold.new(root), head())
        Test.equal(
            observations[root].descriptor.log2_stride,
            254,
            "height plus stride exactly 255 should be accepted"
        )

        base_words[3] = uint_word(255)
        responses[root].tournamentDescriptor = Adapter.decode_result(
            Adapter.View.DESCRIPTOR,
            encoded(base_words)
        )
        Test.error_like("geometry exceeds uint256", function()
            Adapter.observe_fold(transport, Fold.new(root), head())
        end)

        base_words[3] = uint_word(0)
        base_words[4] = uint_word(256)
        responses[root].tournamentDescriptor = Adapter.decode_result(
            Adapter.View.DESCRIPTOR,
            encoded(base_words)
        )
        Test.error_like("geometry exceeds uint256", function()
            Adapter.observe_fold(transport, Fold.new(root), head())
        end)
    end),

    Test.case("root no-winner result is a first-class observation", function()
        local root = address(1)
        local observation_head = head()
        local transport, calls = mock_transport {
            [root] = {
                tournamentDescriptor = descriptor(),
                tournamentStanding = standing(3),
            },
        }
        local observations =
            Adapter.observe_fold(transport, Fold.new(root), observation_head)
        Test.equal(
            observations[root].standing._tag,
            Domain.TournamentStanding.ROOT_FAILED
        )
        Test.equal(#calls, 2)
        for _, call in ipairs(calls) do
            Test.truthy(call.head == observation_head,
                "every point read must use the caller's exact head token")
        end
    end),

    Test.case("phase and tournament-kind cross-product constructs domain variants", function()
        local rows = {
            {
                name = "leaf bisecting",
                descriptor = descriptor(),
                phase = 1,
                projection = bisecting(1, {
                    revealing_parent = digest(30),
                    waiting_left = digest(42),
                }),
                expected = Domain.LiveMatchState.BISECTING,
            },
            {
                name = "leaf ready",
                descriptor = descriptor(),
                phase = 2,
                projection = ready(2),
                expected = Domain.LiveMatchState.READY_TO_SEAL_LEAF,
            },
            {
                name = "leaf sealed",
                descriptor = descriptor(),
                phase = 3,
                projection = sealed(3),
                expected = Domain.LiveMatchState.SEALED_LEAF,
            },
            {
                name = "nonleaf ready",
                descriptor = descriptor { kind = 1 },
                phase = 2,
                projection = ready(2),
                expected = Domain.LiveMatchState.READY_TO_DELEGATE,
            },
        }
        for _, row in ipairs(rows) do
            local root = address(1)
            local fold, match = live_fold(root)
            if row.phase ~= 1 then
                apply_advances(
                    fold,
                    root,
                    match,
                    3,
                    row.projection.revealing_parent,
                    row.projection.waiting_left
                )
            end
            local transport = mock_transport(live_responses(
                root,
                row.descriptor,
                row.phase,
                row.projection
            ))
            local observations = Adapter.observe_fold(transport, fold, head())
            Test.equal(
                observations[root].matches[match.id_hash].live.state._tag,
                row.expected,
                row.name
            )
        end
    end),

    Test.case("folded advance history must agree with semantic projections", function()
        local root = address(1)
        local fold, match = live_fold(root)
        local projection = bisecting(1, {
            revealing_parent = digest(10),
            waiting_left = digest(11),
            height = 3,
            responder = 1,
        })
        local transport = mock_transport(live_responses(
            root,
            descriptor(),
            1,
            projection
        ))

        Test.error_like("folded MatchAdvanced events", function()
            Adapter.observe_fold(transport, fold, head())
        end)

        apply_advances(fold, root, match, 1, digest(10), digest(11))
        Adapter.observe_fold(transport, fold, head())

        projection.revealing_parent = digest(99)
        Test.error_like("otherParent breadcrumb", function()
            Adapter.observe_fold(transport, fold, head())
        end)
    end),

    Test.case("sealed nonleaf projection validates recursive child topology", function()
        local root = address(1)
        local child = address(2)
        local fold, match = live_fold(root, child)
        local parent_projection = sealed(3)
        local responses = live_responses(
            root,
            descriptor { kind = 1 },
            3,
            parent_projection
        )
        responses[child] = {
            tournamentDescriptor = descriptor {
                initial_hash = parent_projection.agree_state,
                base_cycle = parent_projection.divergence_cycle,
                height = 2,
                level = 1,
                kind = 0,
            },
            tournamentStanding = standing(5),
        }
        local observations = Adapter.observe_fold(
            mock_transport(responses),
            fold,
            head()
        )
        Test.equal(
            observations[root].matches[match.id_hash].live.state._tag,
            Domain.LiveMatchState.AWAITING_CHILD
        )
        Test.equal(
            observations[child].standing.reason,
            Domain.InnerEliminationReason.NO_CANDIDATE
        )
    end),

    Test.case("wrong projection phase requires a canonical zero payload", function()
        local root = address(1)
        local fold = live_fold(root)
        local zero = {
            actual_phase = 2,
            revealing_parent = Hash.zero,
            waiting_left = Hash.zero,
            waiting_right = Hash.zero,
            segment_start_position = 0,
            segment_start_cycle = 0,
            current_height = 0,
            responder = 0,
        }
        local responses = live_responses(
            root,
            descriptor(),
            1,
            zero
        )
        local transport = mock_transport(responses)
        Test.error_like("projection phase", function()
            Adapter.observe_fold(transport, fold, head())
        end)

        zero.waiting_left = digest(99)
        Test.error_like("noncanonical inactive field waitingLeft", function()
            Adapter.observe_fold(transport, fold, head())
        end)
    end),

    Test.case("unknown ABI discriminants and timeout payloads fail closed", function()
        local root = address(1)
        local fold = live_fold(root)
        local responses = live_responses(
            root,
            descriptor(),
            1,
            bisecting(1)
        )
        local transport = mock_transport(responses)
        local rows = {
            {
                message = "unknown tournament kind",
                mutate = function()
                    responses[root].tournamentDescriptor.kind = 9
                end,
                restore = function()
                    responses[root].tournamentDescriptor.kind = 0
                end,
            },
            {
                message = "unknown tournament standing",
                mutate = function()
                    responses[root].tournamentStanding.standing = 9
                end,
                restore = function()
                    responses[root].tournamentStanding.standing = 0
                end,
            },
            {
                message = "unknown match phase",
                mutate = function()
                    responses[root].classifyMatchTimeout.actual_phase = 9
                end,
                restore = function()
                    responses[root].classifyMatchTimeout.actual_phase = 1
                end,
            },
            {
                message = "unknown timeout outcome",
                mutate = function()
                    responses[root].classifyMatchTimeout.outcome = 9
                end,
                restore = function()
                    responses[root].classifyMatchTimeout.outcome = 0
                end,
            },
            {
                message = "requires zero deferred charge",
                mutate = function()
                    responses[root].classifyMatchTimeout.deferred_charge = 1
                end,
                restore = function()
                    responses[root].classifyMatchTimeout.deferred_charge = 0
                end,
            },
            {
                message = "unknown commitment side",
                mutate = function()
                    responses[root].bisectingMatch.responder = 9
                end,
                restore = function()
                    responses[root].bisectingMatch.responder = 0
                end,
            },
        }
        for _, row in ipairs(rows) do
            row.mutate()
            Test.error_like(row.message, function()
                Adapter.observe_fold(transport, fold, head())
            end)
            row.restore()
        end
    end),

    Test.case("fold and standing candidate must identify the same hash", function()
        local root = address(1)
        local candidate = digest(70)
        local fold = Fold.new(root)
        fold:apply(Fold.event(
            root,
            1,
            Fold.Event.commitment_joined(candidate, digest(71))
        ))
        local responses = {
            [root] = {
                tournamentDescriptor = descriptor(),
                tournamentStanding = standing(1, {
                    accepts_joins = true,
                    has_candidate = true,
                    candidate = digest(72),
                }),
            },
        }
        Test.error_like("candidate disagrees", function()
            Adapter.observe_fold(
                mock_transport(responses),
                fold,
                head()
            )
        end)
    end),

    Test.case("inner-winner final state must agree with parent side", function()
        local root = address(1)
        local child = address(2)
        local fold, _, one = live_fold(root, child)
        local child_candidate = digest(80)
        fold:apply(Fold.event(
            child,
            7,
            Fold.Event.commitment_joined(child_candidate, digest(99))
        ))
        local parent_projection = sealed(3, {
            final_state_one = digest(81),
            final_state_two = digest(82),
        })
        local responses = live_responses(
            root,
            descriptor { kind = 1 },
            3,
            parent_projection
        )
        responses[child] = {
            tournamentDescriptor = descriptor {
                initial_hash = parent_projection.agree_state,
                base_cycle = parent_projection.divergence_cycle,
                height = 2,
                level = 1,
                kind = 0,
            },
            tournamentStanding = standing(4, {
                has_candidate = true,
                candidate = child_candidate,
                parent_commitment = one,
            }),
        }
        Test.error_like("final state disagrees", function()
            Adapter.observe_fold(
                mock_transport(responses),
                fold,
                head()
            )
        end)
    end),
}
