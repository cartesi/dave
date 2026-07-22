local Dispatcher = require "player.dispatcher"
local Domain = require "player.domain"
local Fulfiller = require "player.fulfiller"
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

local function recording_sender()
    local sender = { calls = {} }
    local function record(name)
        sender[name] = function(_, ...)
            table.insert(sender.calls, {
                name = name,
                arguments = { ... },
            })
            return true
        end
    end
    for _, name in ipairs {
        "tx_join_tournament",
        "tx_win_timeout_match",
        "tx_advance_match",
        "tx_seal_leaf_match",
        "tx_seal_inner_match",
        "tx_win_leaf_match",
        "tx_win_inner_match",
        "eliminate_match",
        "eliminate_inner_tournament",
    } do
        record(name)
    end
    return sender
end

local function assert_call(sender, expected_name, expected)
    Test.equal(#sender.calls, 1, "dispatch performed more than one mutation")
    local call = sender.calls[1]
    Test.equal(call.name, expected_name)
    Test.equal(#call.arguments, #expected)
    for index, value in ipairs(expected) do
        Test.equal(
            call.arguments[index],
            value,
            "wrong dispatch argument " .. tostring(index)
        )
    end
end

return {
    Test.case("every prepared Hero action dispatches one exact Sender call", function()
        local tournament = address(1)
        local child = address(2)
        local one = digest(1)
        local two = digest(2)
        local match_id = Domain.match_id(one, two)
        local left = digest(3)
        local right = digest(4)
        local next_left = digest(5)
        local next_right = digest(6)
        local agree = digest(7)
        local proof = { digest(8) }
        local machine_proof = "0xproof"

        local fixtures = {
            {
                action = {
                    _tag = Fulfiller.PreparedAction.JOIN,
                    tournament = tournament,
                    final_state = agree,
                    proof = proof,
                    left = left,
                    right = right,
                },
                method = "tx_join_tournament",
                arguments = { tournament, agree, proof, left, right },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.CLAIM_TIMEOUT,
                    tournament = tournament,
                    match_id = match_id,
                    left = left,
                    right = right,
                },
                method = "tx_win_timeout_match",
                arguments = { tournament, one, two, left, right },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.ADVANCE,
                    tournament = tournament,
                    match_id = match_id,
                    left = left,
                    right = right,
                    new_left = next_left,
                    new_right = next_right,
                },
                method = "tx_advance_match",
                arguments = {
                    tournament,
                    one,
                    two,
                    left,
                    right,
                    next_left,
                    next_right,
                },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.SEAL_LEAF,
                    tournament = tournament,
                    match_id = match_id,
                    left = left,
                    right = right,
                    agree_state = agree,
                    proof = proof,
                },
                method = "tx_seal_leaf_match",
                arguments = {
                    tournament,
                    one,
                    two,
                    left,
                    right,
                    agree,
                    proof,
                },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.CREATE_CHILD,
                    tournament = tournament,
                    match_id = match_id,
                    left = left,
                    right = right,
                    agree_state = agree,
                    proof = proof,
                },
                method = "tx_seal_inner_match",
                arguments = {
                    tournament,
                    one,
                    two,
                    left,
                    right,
                    agree,
                    proof,
                },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.PROVE_LEAF,
                    tournament = tournament,
                    match_id = match_id,
                    left = left,
                    right = right,
                    proof = machine_proof,
                },
                method = "tx_win_leaf_match",
                arguments = {
                    tournament,
                    one,
                    two,
                    left,
                    right,
                    machine_proof,
                },
            },
            {
                action = {
                    _tag = Fulfiller.PreparedAction.PROPAGATE_CHILD,
                    parent_tournament = tournament,
                    child_tournament = child,
                    left = left,
                    right = right,
                },
                method = "tx_win_inner_match",
                arguments = { tournament, child, left, right },
            },
        }

        for _, fixture in ipairs(fixtures) do
            local sender = recording_sender()
            Test.truthy(Dispatcher.dispatch(fixture.action, sender))
            assert_call(sender, fixture.method, fixture.arguments)
        end
    end),

    Test.case("each bounded GC intent dispatches one exact Sender call", function()
        local tournament = address(1)
        local child = address(2)
        local one = digest(1)
        local two = digest(2)
        local match_id = Domain.match_id(one, two)

        local match_sender = recording_sender()
        Test.truthy(Dispatcher.dispatch_gc(
            Domain.eliminate_match_intent(tournament, match_id),
            match_sender
        ))
        assert_call(
            match_sender,
            "eliminate_match",
            { tournament, one, two }
        )

        local child_sender = recording_sender()
        Test.truthy(Dispatcher.dispatch_gc(
            Domain.eliminate_child_intent(tournament, child),
            child_sender
        ))
        assert_call(
            child_sender,
            "eliminate_inner_tournament",
            { tournament, child }
        )
    end),
}
