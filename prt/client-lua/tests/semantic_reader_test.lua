local Domain = require "player.domain"
local Fold = require "player.fold"
local Hash = require "cryptography.hash"
local SemanticReader = require "player.semantic_reader"
local Test = require "tests.testlib"

local function digest(byte)
    return Hash:from_digest_hex(
        "0x" .. string.rep(string.format("%02x", byte), 32)
    )
end

local function address(byte)
    return "0x" .. string.rep(string.format("%02x", byte), 20)
end

local function word_hash(value)
    return value:hex_string():sub(3)
end

local function word_uint(value)
    return string.format("%064x", value)
end

local function address_topic(value)
    return "0x" .. string.rep("0", 24) .. value:sub(3)
end

local function data(words)
    return "0x" .. table.concat(words or {})
end

local topics = SemanticReader.event_topics()

local function event_commitment_joined(commitment, final_state, submitter)
    return {
        topics = {
            topics[1],
            commitment:hex_string(),
            address_topic(submitter),
        },
        data = data {
            word_hash(final_state),
        },
    }
end

local function event_match_created(one, two, left)
    return {
        topics = {
            topics[2],
            one:join(two):hex_string(),
            one:hex_string(),
            two:hex_string(),
        },
        data = data { word_hash(left) },
    }
end

local function event_match_advanced(id_hash, other_parent, left)
    return {
        topics = {
            topics[3],
            id_hash:hex_string(),
        },
        data = data {
            word_hash(other_parent),
            word_hash(left),
        },
    }
end

local function event_match_deleted(id_hash, one, two, reason, winner)
    return {
        topics = {
            topics[4],
            id_hash:hex_string(),
            one:hex_string(),
            two:hex_string(),
        },
        data = data {
            word_uint(reason),
            word_uint(winner),
        },
    }
end

local function event_new_inner(id_hash, child)
    return {
        topics = {
            topics[5],
            id_hash:hex_string(),
            address_topic(child),
        },
        data = "0x",
    }
end

local function chain_head(number, byte, parent_byte)
    return {
        number = number,
        hash = digest(byte):hex_string(),
        parent_hash = digest(parent_byte):hex_string(),
    }
end

local function raw_log(args)
    local removed = args.removed
    if removed == nil then
        removed = false
    end
    return {
        address = args.address,
        block_number = args.block,
        block_hash = args.block_hash,
        transaction_hash = args.transaction_hash or digest(
            100 + args.transaction_index
        ):hex_string(),
        transaction_index = args.transaction_index,
        log_index = args.log_index,
        removed = removed,
        topics = args.event.topics,
        data = args.event.data,
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
        levels = fields.levels or 2,
        kind = fields.kind == nil and 1 or fields.kind,
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

local function semantic_fixture()
    local root = address(1)
    local child = address(2)
    local submitter = address(3)
    local one = digest(10)
    local two = digest(11)
    local child_candidate = digest(12)
    local final_one = digest(20)
    local final_two = digest(21)
    local child_final = digest(22)
    local left = digest(30)
    local id_hash = one:join(two)
    local agree_state = digest(40)

    local block9 = chain_head(9, 209, 208)
    local finalized = chain_head(10, 210, 209)
    local block11 = chain_head(11, 211, 210)
    local head = chain_head(12, 212, 211)
    local transaction12 = digest(112):hex_string()

    local logs = {
        root_range = {
            raw_log {
                address = root,
                block = 9,
                block_hash = block9.hash,
                transaction_index = 0,
                log_index = 0,
                event =
                    event_commitment_joined(one, final_one, submitter),
            },
            raw_log {
                address = root,
                block = 10,
                block_hash = finalized.hash,
                transaction_index = 0,
                log_index = 0,
                event =
                    event_commitment_joined(two, final_two, submitter),
            },
        },
        root_11 = {
            raw_log {
                address = root,
                block = 11,
                block_hash = block11.hash,
                transaction_index = 0,
                log_index = 2,
                event = event_match_created(one, two, left),
            },
            raw_log {
                address = root,
                block = 11,
                block_hash = block11.hash,
                transaction_index = 0,
                log_index = 3,
                event = event_match_advanced(id_hash, digest(31), digest(32)),
            },
            raw_log {
                address = root,
                block = 11,
                block_hash = block11.hash,
                transaction_index = 0,
                log_index = 4,
                event = event_match_advanced(id_hash, digest(33), digest(34)),
            },
            raw_log {
                address = root,
                block = 11,
                block_hash = block11.hash,
                transaction_index = 0,
                log_index = 5,
                event = event_match_advanced(id_hash, digest(35), digest(36)),
            },
        },
        root_12 = {
            raw_log {
                address = root,
                block = 12,
                block_hash = head.hash,
                transaction_hash = transaction12,
                transaction_index = 0,
                log_index = 3,
                event = event_new_inner(id_hash, child),
            },
        },
        child_12 = {
            raw_log {
                address = child,
                block = 12,
                block_hash = head.hash,
                transaction_hash = transaction12,
                transaction_index = 0,
                log_index = 4,
                event = event_commitment_joined(
                    child_candidate,
                    child_final,
                    submitter
                ),
            },
        },
    }

    local divergence = {
        actual_phase = 3,
        agree_state = agree_state,
        divergence_position = 3,
        divergence_cycle = 3,
        final_state_one = child_final,
        final_state_two = digest(41),
    }
    local responses = {
        [root] = {
            tournamentDescriptor = descriptor(),
            tournamentStanding = standing(0),
            matchTimeoutStatus = {
                actual_phase = 3,
                outcome = 0,
                deferred_charge = 0,
            },
            sealedMatch = divergence,
        },
        [child] = {
            tournamentDescriptor = descriptor {
                initial_hash = agree_state,
                base_cycle = 3,
                height = 2,
                level = 1,
                levels = 2,
                kind = 0,
            },
            tournamentStanding = standing(1, {
                accepts_joins = true,
                has_candidate = true,
                candidate = child_candidate,
            }),
        },
    }
    return {
        root = root,
        child = child,
        one = one,
        two = two,
        child_candidate = child_candidate,
        block9 = block9,
        finalized = finalized,
        block11 = block11,
        head = head,
        logs = logs,
        responses = responses,
    }
end

local function mock_transport(fixture)
    local calls = {
        ranges = {},
        exact = {},
        observer = {},
        final_checks = 0,
    }
    local transport = {
        final_head = fixture.head,
    }

    function transport.get_head(_, tag)
        if tag == "finalized" then
            return fixture.finalized
        end
        assert(tag == "latest")
        return fixture.head
    end

    function transport.get_block_by_hash(_, hash)
        if hash == fixture.block11.hash then
            return fixture.block11
        end
        if hash == fixture.finalized.hash then
            return fixture.finalized
        end
        error("unexpected ancestry hash " .. tostring(hash))
    end

    function transport:get_block_by_number(number)
        calls.final_checks = calls.final_checks + 1
        Test.equal(number, fixture.head.number)
        return self.final_head
    end

    function transport.get_logs_range(_, at, from, to, requested_topics)
        table.insert(calls.ranges, { address = at, from = from, to = to })
        Test.equal(#requested_topics, 5)
        if at == fixture.root then
            return fixture.logs.root_range
        end
        Test.equal(at, fixture.child)
        return {}
    end

    function transport.get_logs_at_block(_, at, block, requested_topics)
        table.insert(calls.exact, { address = at, block = block.number })
        Test.equal(#requested_topics, 5)
        if at == fixture.root and block.number == 11 then
            return fixture.logs.root_11
        end
        if at == fixture.root and block.number == 12 then
            return fixture.logs.root_12
        end
        if at == fixture.child and block.number == 12 then
            return fixture.logs.child_12
        end
        return {}
    end

    function transport.observer_call(_, at, view, argument, observation_head)
        table.insert(calls.observer, {
            address = at,
            view = view.name,
            argument = argument,
            head = observation_head,
        })
        local tournament = assert(
            fixture.responses[at],
            "unexpected observer tournament"
        )
        return assert(tournament[view.name], "unexpected observer view")
    end

    return transport, calls
end

return {
    Test.case("raw decoder covers all five structural event shapes", function()
        local tournament = address(1):upper():gsub("^0X", "0x")
        local submitter = address(2)
        local child = address(3)
        local one = digest(1)
        local two = digest(2)
        local id_hash = one:join(two)
        local rows = {
            {
                tag = Fold.EventKind.COMMITMENT_JOINED,
                event =
                    event_commitment_joined(one, digest(4), submitter),
            },
            {
                tag = Fold.EventKind.MATCH_CREATED,
                event = event_match_created(one, two, digest(5)),
            },
            {
                tag = Fold.EventKind.MATCH_ADVANCED,
                event =
                    event_match_advanced(id_hash, digest(6), digest(7)),
            },
            {
                tag = Fold.EventKind.MATCH_DELETED,
                event =
                    event_match_deleted(id_hash, one, two, 1, 2),
            },
            {
                tag = Fold.EventKind.NEW_INNER_TOURNAMENT,
                event = event_new_inner(id_hash, child),
            },
        }
        for index, row in ipairs(rows) do
            local decoded = SemanticReader.decode_event_log {
                address = tournament,
                block_number = 10 + index,
                topics = row.event.topics,
                data = row.event.data,
            }
            Test.equal(decoded.tournament, address(1))
            Test.equal(decoded.kind._tag, row.tag)
            if row.tag == Fold.EventKind.COMMITMENT_JOINED then
                Test.truthy(Hash:is_of_type_hash(decoded.kind.root))
            elseif row.tag == Fold.EventKind.NEW_INNER_TOURNAMENT then
                Test.equal(decoded.kind.child, child)
            end
        end
    end),

    Test.case("raw decoder rejects unknown and noncanonical event tags", function()
        local one = digest(1)
        local two = digest(2)
        local deletion =
            event_match_deleted(one:join(two), one, two, 9, 0)
        Test.error_like("unknown match deletion reason", function()
            SemanticReader.decode_event_log {
                address = address(1),
                block_number = 1,
                topics = deletion.topics,
                data = deletion.data,
            }
        end)

        Test.error_like("unknown structural event topic", function()
            SemanticReader.decode_event_log {
                address = address(1),
                block_number = 1,
                topics = { digest(99):hex_string() },
                data = "0x",
            }
        end)

        local child_event = event_new_inner(one:join(two), address(3))
        child_event.topics[3] =
            "0x01" .. child_event.topics[3]:sub(5)
        Test.error_like("canonical indexed address", function()
            SemanticReader.decode_event_log {
                address = address(1),
                block_number = 1,
                topics = child_event.topics,
                data = child_event.data,
            }
        end)
    end),

    Test.case("reader closes dynamic discovery over one globally ordered replay", function()
        local fixture = semantic_fixture()
        local transport, calls = mock_transport(fixture)
        local result = SemanticReader.new(
            fixture.root:upper():gsub("^0X", "0x"),
            9,
            transport
        ):fetch()

        Test.equal(result.head.hash, fixture.head.hash)
        Test.equal(#result.fold:addresses(), 2)
        Test.truthy(result.fold:tournament(fixture.child),
            "child stream must be discovered and replayed")
        Test.equal(
            result.fold:candidate(fixture.child),
            fixture.child_candidate
        )
        Test.equal(
            result.observations[fixture.root].match_order[1].live.state._tag,
            Domain.LiveMatchState.AWAITING_CHILD
        )
        Test.equal(
            result.observations[fixture.child].standing._tag,
            Domain.TournamentStanding.AWAITING_CLOSURE
        )
        Test.equal(#calls.ranges, 2)
        Test.equal(#calls.exact, 4)
        Test.equal(calls.final_checks, 1)
        for _, call in ipairs(calls.observer) do
            Test.equal(call.head.hash, fixture.head.hash,
                "observer call escaped the sampled exact head")
            Test.equal(call.head.number, fixture.head.number)
        end
    end),

    Test.case("reader rejects a head that changes before return", function()
        local fixture = semantic_fixture()
        local transport = mock_transport(fixture)
        transport.final_head = chain_head(12, 250, 211)
        Test.error_like("no longer canonical", function()
            SemanticReader.new(fixture.root, 9, transport):fetch()
        end)
    end),

    Test.case("reader proves finalized membership in latest ancestry", function()
        local fixture = semantic_fixture()
        local transport = mock_transport(fixture)
        function transport.get_head(_, tag)
            if tag == "finalized" then
                return chain_head(10, 250, 209)
            end
            assert(tag == "latest")
            return fixture.head
        end
        Test.error_like("not on latest-head ancestry", function()
            SemanticReader.new(fixture.root, 9, transport):fetch()
        end)
    end),

    Test.case("global log normalization rejects malformed provenance", function()
        local fixture = semantic_fixture()
        local base = fixture.logs.root_11[1]
        local function copy(overrides)
            local value = {}
            for key, field in pairs(base) do
                value[key] = field
            end
            for key, field in pairs(overrides or {}) do
                value[key] = field
            end
            return value
        end

        local rows = {
            {
                message = "marked removed",
                logs = { copy { removed = true } },
            },
            {
                message = "must be a 32-byte hex value",
                logs = { copy { transaction_hash = false } },
            },
            {
                message = "conflicting hashes across",
                logs = {
                    copy { log_index = 0 },
                    copy {
                        block_hash = digest(250):hex_string(),
                        log_index = 1,
                    },
                },
            },
            {
                message = "transaction index 0 has conflicting hashes",
                logs = {
                    copy { log_index = 0 },
                    copy {
                        transaction_hash = digest(251):hex_string(),
                        log_index = 1,
                    },
                },
            },
            {
                message = "repeats global log index",
                logs = {
                    copy { log_index = 0 },
                    copy { log_index = 0 },
                },
            },
            {
                message = "transaction order contradicts",
                logs = {
                    copy {
                        transaction_hash = digest(252):hex_string(),
                        transaction_index = 1,
                        log_index = 0,
                    },
                    copy {
                        transaction_hash = digest(253):hex_string(),
                        transaction_index = 0,
                        log_index = 1,
                    },
                },
            },
        }
        for _, row in ipairs(rows) do
            Test.error_like(row.message, function()
                SemanticReader.normalize_logs(row.logs)
            end)
        end
    end),

    Test.case("exact-tail log hash must match sampled ancestry", function()
        local fixture = semantic_fixture()
        fixture.logs.root_12[1].block_hash = digest(250):hex_string()
        local transport = mock_transport(fixture)
        Test.error_like("wrong exact block", function()
            SemanticReader.new(fixture.root, 9, transport):fetch()
        end)
    end),

    Test.case("finalized range cannot smuggle an unfinalized log", function()
        local fixture = semantic_fixture()
        table.insert(fixture.logs.root_range, fixture.logs.root_11[1])
        local transport = mock_transport(fixture)
        Test.error_like("finalized range [9, 10] returned block 11", function()
            SemanticReader.new(fixture.root, 9, transport):fetch()
        end)
    end),
}
