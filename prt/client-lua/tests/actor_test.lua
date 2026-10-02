local Actor = require "player.actor"
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

local function tree()
    local initial = digest(1)
    local builder = MerkleBuilder:new()
    for byte = 10, 13 do
        builder:add(digest(byte))
    end
    return initial, builder:build(initial)
end

local function descriptor(root, initial)
    return Domain.descriptor {
        address = root,
        level = 0,
        kind = Domain.TournamentKind.LEAF,
        initial_hash = initial,
        base_cycle = 0,
        log2_stride = 0,
        height = 2,
        start_instant = 1,
        allowance = 1000,
    }
end

local function live(state, timeout)
    return Domain.live(state, timeout or Domain.timeout_none())
end

local function bisecting(revealing_parent, waiting_left, waiting_right)
    return Domain.bisecting {
        revealing_parent = revealing_parent,
        waiting_children =
            Domain.waiting_children(waiting_left, waiting_right),
        coordinate = Domain.coordinate(0, 0),
        remaining_height = 2,
        responder = Domain.MatchSide.ONE,
    }
end

local function reader_for(fold, observations)
    return {
        fetch = function()
            return {
                head = { number = 9, hash = digest(90):hex_string() },
                fold = fold,
                observations = observations,
            }
        end,
    }
end

local function commitment_builder(local_tree)
    return {
        build = function()
            return local_tree
        end,
    }
end

local function recording_sender()
    return {
        index = 99,
        tx_count = 0,
        calls = {},
        tx_advance_match = function(self, ...)
            self.tx_count = self.tx_count + 1
            table.insert(self.calls, {
                name = "advance",
                arguments = { ... },
            })
            return true
        end,
    }
end

local function join(fold, root, commitment, final_state)
    fold:apply(Fold.event(
        root,
        1,
        Fold.Event.commitment_joined(commitment, final_state)
    ))
end

local function create_match(fold, root, one, two, block)
    fold:apply(Fold.event(
        root,
        block,
        Fold.Event.match_created(
            one,
            two,
            digest(80 + block),
            one:join(two),
            block + 1
        )
    ))
    return fold:live_matches(root)[#fold:live_matches(root)]
end

return {
    Test.case("actor dispatches one Hero action per observation", function()
        local root = address(1)
        local initial, local_tree = tree()
        local opponent = digest(30)
        local gc_one = digest(40)
        local gc_two = digest(41)
        local fold = Fold.new(root)
        for _, commitment in ipairs {
            local_tree.root_hash,
            opponent,
            gc_one,
            gc_two,
        } do
            join(fold, root, commitment, digest(50))
        end
        local hero_match = create_match(
            fold,
            root,
            local_tree.root_hash,
            opponent,
            2
        )
        local gc_match = create_match(fold, root, gc_one, gc_two, 3)
        local observation = Domain.tournament_observation(
            descriptor(root, initial),
            Domain.matches_active(nil, Domain.JoinDisposition.OPEN),
            {
                Domain.observed_match(
                    hero_match.id_hash,
                    hero_match.id,
                    live(bisecting(
                        local_tree.root_hash,
                        digest(60),
                        digest(61)
                    ))
                ),
                Domain.observed_match(
                    gc_match.id_hash,
                    gc_match.id,
                    live(
                        bisecting(digest(62), digest(63), digest(64)),
                        Domain.timeout_eliminate_both()
                    )
                ),
            }
        )
        local sender = recording_sender()
        local actor = Actor.new {
            reader = reader_for(fold, { [root] = observation }),
            commitment_builder = commitment_builder(local_tree),
            machine_path = "unused",
            inputs = {},
            sender = sender,
        }
        local log = actor:react()
        Test.equal(#sender.calls, 1)
        Test.equal(sender.calls[1].name, "advance")
        Test.equal(log.decision._tag, Domain.HeroDecision.ACT)
        Test.equal(log.idle, false)
        Test.equal(#log.state.matches, 2)
    end),
}
