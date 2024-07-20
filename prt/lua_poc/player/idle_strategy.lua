local helper = require "utils.helper"

local IdleStrategy = {}
IdleStrategy.__index = IdleStrategy

function IdleStrategy:new(commitment_builder, machine_path, sender)
    local honest_strategy = {
        commitment_builder = commitment_builder,
        machine_path = machine_path,
        sender = sender
    }

    setmetatable(honest_strategy, self)
    return honest_strategy
end

function IdleStrategy:_join_tournament(tournament, commitment)
    local f, left, right = commitment:children(commitment.root_hash)
    assert(f)
    local last, proof = commitment:last()

    helper.log_timestamp(string.format(
        "join tournament %s of level %d with commitment %s",
        tournament.address,
        tournament.level,
        commitment.root_hash
    ))
    local ok, e = self.sender:tx_join_tournament(
        tournament.address,
        last,
        proof,
        left,
        right
    )
    if not ok then
        helper.log_timestamp(string.format(
            "join tournament reverted: %s",
            e
        ))
    end
end

function IdleStrategy:_react_tournament(_, tournament)
    helper.log_timestamp("Enter tournament at address: " .. tournament.address)
    local commitment = self.commitment_builder:build(
        tournament.base_big_cycle,
        tournament.level,
        tournament.log2_stride,
        tournament.log2_stride_count
    )

    local tournament_winner = tournament.tournament_winner
    if tournament_winner[1] == "true" then
        if not tournament.parent then
            helper.log_timestamp("TOURNAMENT FINISHED, HURRAYYY")
            helper.log_timestamp("Winner commitment: " .. tournament_winner[2]:hex_string())
            helper.log_timestamp("Final state: " .. tournament_winner[3]:hex_string())
            return true
        end
    end

    if not tournament.commitments[commitment.root_hash] then
        self:_join_tournament(tournament, commitment)
    else
        local commitment_clock = tournament.commitments[commitment.root_hash].status.clock
        helper.log_timestamp(tostring(commitment_clock))
    end
end

function IdleStrategy:react(state)
    return self:_react_tournament(state, state.root_tournament)
end

return IdleStrategy
