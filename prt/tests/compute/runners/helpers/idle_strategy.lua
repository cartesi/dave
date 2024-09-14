local helper = require "utils.helper"

local IdleStrategy = {}
IdleStrategy.__index = IdleStrategy

function IdleStrategy:new(commitment_builder, sender)
    local idle_strategy = {
        commitment_builder = commitment_builder,
        sender = sender
    }

    setmetatable(idle_strategy, self)
    return idle_strategy
end

function IdleStrategy:_join_tournament(tournament, commitment)
    local f, left, right = commitment:children(commitment.root_hash)
    assert(f)
    local last, proof = commitment:last()

    helper.log_full(self.sender.index, string.format(
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
        helper.log_full(self.sender.index, string.format(
            "join tournament reverted: %s",
            e
        ))
    end
end

function IdleStrategy:_react_tournament(tournament)
    helper.log_full(self.sender.index, "Enter tournament at address: " .. tournament.address)
    local commitment = self.commitment_builder:build(
        tournament.base_big_cycle,
        tournament.level,
        tournament.log2_stride,
        tournament.log2_stride_count
    )

    local tournament_winner = tournament.tournament_winner
    if tournament_winner.has_winner then
        if not tournament.parent then
            helper.log_full(self.sender.index, "TOURNAMENT FINISHED, HURRAYYY")
            helper.log_full(self.sender.index, "Winner commitment: " .. tournament_winner.commitment:hex_string())
            helper.log_full(self.sender.index, "Final state: " .. tournament_winner.final:hex_string())
            return true
        end
    end

    if not tournament.commitments[commitment.root_hash] then
        self:_join_tournament(tournament, commitment)
    else
        local commitment_clock = tournament.commitments[commitment.root_hash].status.clock
        helper.log_full(self.sender.index, tostring(commitment_clock))
    end
end

function IdleStrategy:react(tournament)
    local tx_count = self.sender.tx_count

    local finished = self:_react_tournament(tournament)
    local idle = tx_count == self.sender.tx_count

    return {
        idle = idle,
        finished = finished
    }
end

return IdleStrategy
