local Adapter = require "player.adapter"
local CommitmentBuilder = require "computation.commitment"
local Hash = require "cryptography.hash"
local PatchedCommitmentBuilder =
    require "runners.helpers.patched_commitment"
local PlayerSender = require "player.sender"
local SemanticReader = require "player.semantic_reader"
local start_sybil = require "runners.sybil_runner"
local time = require "utils.time"

local env = require "test_env"

local SealedLeafTimeout = {}

-- Wide enough to probe past the legacy midpoint and still include one
-- transaction before the longer deadline.
local DESIRED_DEADLINE_GAP = 80
local MAX_PLAYER_ROUNDS = 5000
local SEALED_PHASE = 3
local TIMEOUT_NONE = 0
local TIMEOUT_TWO_WINS = 2
local TIMEOUT_ELIMINATE_BOTH = 3
local TOURNAMENT_ARGUMENTS_SIGNATURE = table.concat {
    "tournamentArguments()(",
    "((bytes32,uint256,uint64,uint64),",
    "uint64,uint64,uint64,uint64,uint64,address,",
    "(bytes32,bytes32,bytes32,bytes32),address,address))",
}

local function response_budget(tournament)
    -- This parameter controls the final response discount, so the fixture
    -- reads it from the actual clone's immutable arguments instead of
    -- mirroring deployment policy.
    local values = env.reader.inner_reader:read_clone_args(
        tournament,
        TOURNAMENT_ARGUMENTS_SIGNATURE
    )
    assert(#values == 1, "tournamentArguments decoded an unexpected shape")

    local compact = values[1]:gsub("%b[]", ""):gsub("%s+", "")
    local inner_end = assert(
        compact:find(")", 3, true),
        "tournamentArguments omitted commitment arguments"
    )
    local scalars = compact:sub(inner_end + 2)
    local _, _, _, _, budget = scalars:match(
        "^(%d+),(%d+),(%d+),(%d+),(%d+),"
    )
    return assert(tonumber(budget), "could not decode responseBudget")
end

local function advance_to(block_number)
    local current = tonumber(
        env.reader.inner_reader:_get_block_number("latest")
    )
    assert(block_number >= current, string.format(
        "cannot advance backward from block %d to %d",
        current,
        block_number
    ))
    if block_number > current then
        env.sender:advance_blocks(block_number - current)
    end
end

local function zero_word(value)
    return type(value) == "string"
        and value:match("^0[xX]0+$") ~= nil
end

local function timeout_at(fixture, block_number, outcome)
    local transport = fixture.transport
    local head = transport:get_block_by_number(block_number)
    local wire = transport:observer_call(
        fixture.leaf_tournament,
        Adapter.View.TIMEOUT,
        fixture.match_id,
        head
    )
    assert(wire.actual_phase == SEALED_PHASE, string.format(
        "timeout view at block %d is not SEALED",
        block_number
    ))
    assert(wire.outcome == outcome, string.format(
        "timeout view at block %d returned outcome %d, expected %d",
        block_number,
        wire.outcome,
        outcome
    ))
    assert(zero_word(wire.deferred_charge),
        "sealed-leaf timeout returned a deferred charge")
    return wire
end

local function wait_for_honest_root_join(sealed_epoch, commitment)
    time.sleep_until(function()
        if env.reader:commitment_exists(
            sealed_epoch.tournament,
            commitment
        ) then
            return true
        end
        env.sender:advance_blocks(1)
        return false
    end)
end

local function eager_drive_until_sealed(player, fixture)
    local rounds = 0
    while not fixture.sealed do
        rounds = rounds + 1
        assert(rounds <= MAX_PLAYER_ROUNDS,
            "sealed-leaf setup did not converge")

        local status, log = env.player_react(player)
        assert(status ~= "dead",
            "sybil stopped before sealing the leaf match")
        assert(not log.has_lost,
            "sybil lost before sealing the leaf match")

        if not fixture.sealed and log.idle then
            env.sender:advance_blocks(1)
            time.sleep(env.sleep_time)
        end
    end
end

local function install_sender_hooks(sender, fixture)
    local joined = {}
    local inner_heights = {}
    local child_join_pending = false

    -- Height parity chooses the final responder. Stop the node around each
    -- child creation so the sybil joins the child first and becomes
    -- commitment one at the odd-height inner and leaf levels.
    function sender:tx_join_tournament(
        tournament,
        final_state,
        proof,
        left,
        right
    )
        local root = left:join(right)
        local ok, result = PlayerSender.tx_join_tournament(
            self,
            tournament,
            final_state,
            proof,
            left,
            right
        )
        if ok then
            joined[tournament:lower()] = root
            if child_join_pending then
                child_join_pending = false
                env.dave_node:respawn()
            end
        end
        return ok, result
    end

    function sender:tx_seal_inner_match(
        tournament,
        commitment_one,
        commitment_two,
        left,
        right,
        initial_hash,
        proof
    )
        local constants =
            env.reader.inner_reader:read_constants(tournament)
        env.dave_node:kill()
        local ok, result = PlayerSender.tx_seal_inner_match(
            self,
            tournament,
            commitment_one,
            commitment_two,
            left,
            right,
            initial_hash,
            proof
        )
        if ok then
            table.insert(inner_heights, constants.height)
            child_join_pending = true
        else
            env.dave_node:respawn()
        end
        return ok, result
    end

    function sender:tx_seal_leaf_match(
        tournament,
        commitment_one,
        commitment_two,
        left,
        right,
        initial_hash,
        proof
    )
        assert(not fixture.sealed, "leaf match was sealed twice")
        local constants =
            env.reader.inner_reader:read_constants(tournament)
        assert(constants.level == constants.max_level - 1,
            "seal hook reached a non-leaf tournament")
        assert(constants.height == 27,
            "canonical leaf tournament height changed")
        assert(#inner_heights == 2
            and inner_heights[1] == 48
            and inner_heights[2] == 17,
            "eager setup did not traverse the canonical 48/17/27 levels")

        local sybil_commitment = joined[tournament:lower()]
        assert(sybil_commitment,
            "sybil leaf commitment was not captured")
        assert(sybil_commitment == commitment_one,
            "sybil must be commitment one and the final leaf responder")

        env.dave_node:kill()

        local reader = env.reader.inner_reader
        local before_one =
            reader:read_commitment(tournament, commitment_one)
        local before_two =
            reader:read_commitment(tournament, commitment_two)
        assert(before_one.clock.last_resume > 0,
            "commitment one is not the final running responder")
        assert(before_two.clock.last_resume == 0,
            "commitment two must be paused before leaf sealing")
        assert(before_one.clock.block_number == before_two.clock.block_number,
            "pre-seal clocks came from different blocks")

        local effort = response_budget(tournament)
        local target_one_allowance =
            before_two.clock.allowance - DESIRED_DEADLINE_GAP
        assert(target_one_allowance > 0,
            "honest allowance is too small for the requested deadline gap")

        local required_charge =
            math.max(before_one.clock.allowance - target_one_allowance, 0)
        local minimum_inclusion = before_one.clock.block_number + 1
        -- pauseAfterResponseAt charges max(elapsed - responseBudget, 0).
        -- Choose the seal block from that equation, then let cast send mine
        -- exactly the final block.
        local target_inclusion = math.max(
            minimum_inclusion,
            before_one.clock.last_resume + effort + required_charge
        )
        local charged = math.max(
            target_inclusion - before_one.clock.last_resume - effort,
            0
        )
        assert(target_inclusion
            < before_one.clock.last_resume + before_one.clock.allowance,
            "controlled sealing delay would expire the sybil")

        advance_to(target_inclusion - 1)
        local ok, result = PlayerSender.tx_seal_leaf_match(
            self,
            tournament,
            commitment_one,
            commitment_two,
            left,
            right,
            initial_hash,
            proof
        )
        assert(ok, "controlled leaf seal reverted: " .. tostring(result))

        local after_one =
            reader:read_commitment(tournament, commitment_one)
        local after_two =
            reader:read_commitment(tournament, commitment_two)
        assert(after_one.clock.last_resume == target_inclusion
            and after_two.clock.last_resume == target_inclusion,
            "sealed leaf clocks did not start at one common block")
        assert(after_one.clock.allowance
            == before_one.clock.allowance - charged,
            "final responder charge differs from the computed delay")
        assert(after_two.clock.allowance == before_two.clock.allowance,
            "paused commitment was charged by leaf sealing")
        assert(after_two.clock.allowance - after_one.clock.allowance
            >= DESIRED_DEADLINE_GAP,
            "controlled seal did not create the required deadline gap")

        fixture.sealed = true
        fixture.leaf_tournament = tournament
        fixture.match_id = {
            commitment_one = commitment_one,
            commitment_two = commitment_two,
        }
        fixture.match = {
            match_id_hash = commitment_one:join(commitment_two),
            commitment_one = commitment_one,
            commitment_two = commitment_two,
        }
        fixture.seal_block = target_inclusion
        fixture.short_allowance = after_one.clock.allowance
        fixture.long_allowance = after_two.clock.allowance
        fixture.short_deadline =
            target_inclusion + after_one.clock.allowance
        fixture.long_deadline =
            target_inclusion + after_two.clock.allowance

        print(string.format(
            "[sealed_leaf_timeout] seal=%d short=%d long=%d gap=%d effort=%d",
            fixture.seal_block,
            fixture.short_deadline,
            fixture.long_deadline,
            fixture.long_deadline - fixture.short_deadline,
            effort
        ))
        return ok, result
    end
end

local function setup()
    env.spawn_blockchain { env.sample_inputs[1] }
    local first_epoch = assert(env.reader:read_epochs_sealed()[1])
    assert(first_epoch.input_upper_bound == 0,
        "epoch zero must be empty")

    env.sender:tx_add_inputs {
        env.sample_inputs[1],
        env.sample_inputs[1],
        env.sample_inputs[1],
    }
    env.spawn_node()

    local sealed_epoch = env.roll_epoch()
    assert(sealed_epoch.epoch_number == 1,
        "timeout scenario expected epoch one")
    local settlement = env.epoch_settlement(sealed_epoch)
    wait_for_honest_root_join(
        sealed_epoch,
        settlement.commitment.root_hash
    )

    local honest_builder = CommitmentBuilder:new(
        settlement.machine_path,
        settlement.inputs,
        settlement.commitment
    )
    local sybil_builder = PatchedCommitmentBuilder:new({
        {
            hash = Hash.zero,
            meta_cycle = 1 << 44,
        },
    }, honest_builder)

    local fixture = {
        transport =
            SemanticReader.CastTransport.new(env.blockchain.endpoint),
        sealed = false,
    }
    local sender = PlayerSender:new(
        env.blockchain.pks[2],
        2,
        env.blockchain.endpoint
    )
    install_sender_hooks(sender, fixture)
    local player = start_sybil(
        sybil_builder,
        settlement.machine_path,
        sealed_epoch.tournament,
        settlement.inputs,
        2,
        {
            sender = sender,
            gc_enabled = false,
        }
    )
    eager_drive_until_sealed(player, fixture)
    assert(fixture.short_deadline < fixture.long_deadline,
        "sealed leaf did not produce ordered deadlines")
    return fixture
end

local function wait_for_deletion(fixture, winner)
    -- The sybil coroutine is never resumed after fixture.sealed. With its GC
    -- disabled, only the respawned Rust node can emit this deletion.
    time.sleep_until(function()
        return #env.reader:read_match_deleted(
            fixture.leaf_tournament,
            fixture.match.match_id_hash
        ) > 0
    end)
    return env.assert_match_deleted(
        fixture.leaf_tournament,
        fixture.match,
        "timeout",
        winner
    )
end

function SealedLeafTimeout.longer_wins_after_midpoint()
    local fixture = setup()
    advance_to(fixture.short_deadline - 1)
    timeout_at(
        fixture,
        fixture.short_deadline - 1,
        TIMEOUT_NONE
    )
    advance_to(fixture.short_deadline)
    timeout_at(
        fixture,
        fixture.short_deadline,
        TIMEOUT_TWO_WINS
    )

    -- The retired classifier changed outcome at
    -- seal + ceil((short + long) / 2).
    local former_midpoint = fixture.seal_block
        + (fixture.short_allowance + fixture.long_allowance + 1) // 2
    local observation_block = former_midpoint + 1
    assert(observation_block + 1 < fixture.long_deadline,
        "deadline gap leaves no transaction-inclusion margin")
    advance_to(observation_block)
    timeout_at(fixture, observation_block, TIMEOUT_TWO_WINS)

    env.dave_node:respawn()
    local deletion = wait_for_deletion(fixture, "two")
    assert(deletion.meta.block_number == observation_block + 1,
        "timeout victory was not included in the first block after observation")
    assert(deletion.meta.block_number > former_midpoint,
        "timeout victory did not cross the former midpoint")
    assert(deletion.meta.block_number < fixture.long_deadline,
        "timeout victory landed after the longer clock expired")

    print(string.format(
        "[sealed_leaf_timeout] longer clock won in block %d after midpoint %d",
        deletion.meta.block_number,
        former_midpoint
    ))
end

function SealedLeafTimeout.both_eliminate_at_long_deadline()
    local fixture = setup()
    advance_to(fixture.long_deadline - 1)
    timeout_at(
        fixture,
        fixture.long_deadline - 1,
        TIMEOUT_TWO_WINS
    )
    advance_to(fixture.long_deadline)
    timeout_at(
        fixture,
        fixture.long_deadline,
        TIMEOUT_ELIMINATE_BOTH
    )

    env.dave_node:respawn()
    local deletion = wait_for_deletion(fixture, "none")
    assert(deletion.meta.block_number == fixture.long_deadline + 1,
        "double elimination was not included immediately after the exact boundary")

    print(string.format(
        "[sealed_leaf_timeout] both clocks eliminated after exact deadline %d",
        fixture.long_deadline
    ))
end

return SealedLeafTimeout
