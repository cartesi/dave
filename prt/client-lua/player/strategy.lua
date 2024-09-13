local helper = require "utils.helper"
local Machine = require "computation.machine"
local constants = require "computation.constants"
local GarbageCollector = require "player.gc"

local HonestStrategy = {}
HonestStrategy.__index = HonestStrategy

function HonestStrategy:new(commitment_builder, machine_path, sender)
    local gc_strategy = GarbageCollector:new(sender)

    local honest_strategy = {
        commitment_builder = commitment_builder,
        machine_path = machine_path,
        sender = sender,
        gc_strategy = gc_strategy,
    }

    setmetatable(honest_strategy, self)
    return honest_strategy
end

function HonestStrategy:disable_gc()
    self.gc_strategy = false
end

function HonestStrategy:enable_gc()
    self.gc_strategy = GarbageCollector:new(self.sender)
end

function HonestStrategy:_join_tournament(tournament, commitment)
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

function HonestStrategy:_react_match(match, commitment, log)
    helper.log_timestamp("Enter match at HEIGHT: " .. match.current_height)

    local opponent_clock = commitment.root_hash == match.commitment_one and
        match.tournament.commitments[match.commitment_two].status.clock or
        match.tournament.commitments[match.commitment_one].status.clock

    if not opponent_clock:has_time() then
        local f, left, right = commitment.root_hash:children()
        assert(f)

        helper.log_timestamp(string.format("win match by timeout in tournament %s of level %d for commitment %s",
            match.tournament.address,
            match.tournament.level,
            commitment.root_hash))

        local ok, e = self.sender:tx_win_timeout_match(
            match.tournament.address,
            match.commitment_one,
            match.commitment_two,
            left,
            right
        )
        if not ok then
            helper.log_timestamp(string.format(
                "win timeout match reverted: %s",
                e
            ))
        end
        return
    end

    if match.current_height == 0 then
        -- match sealed
        if match.tournament.level == (match.tournament.max_level - 1) then
            local f, left, right = commitment.root_hash:children()
            assert(f)

            helper.log_timestamp(string.format(
                "Calculating access logs for step %s",
                match.running_leaf
            ))

            local cycle = match.base_big_cycle
            local ucycle = (match.leaf_cycle & constants.uarch_span):touinteger()
            local logs = Machine:get_logs(self.machine_path, cycle, ucycle)

            helper.log_timestamp(string.format(
                "win leaf match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment.root_hash
            ))
            local ok, e = self.sender:tx_win_leaf_match(
                match.tournament.address,
                match.commitment_one,
                match.commitment_two,
                left,
                right,
                logs
            )
            if not ok then
                helper.log_timestamp(string.format(
                    "win leaf match reverted: %s",
                    e
                ))
            end
        elseif match.inner_tournament then
            return self:_react_tournament(match.inner_tournament, log)
        end
    elseif match.current_height == 1 then
        -- match to be sealed
        local found, left, right = match.current_other_parent:children()
        if not found then
            return
        end

        local running_leaf
        if left ~= match.current_left then
            -- disagree on left
            running_leaf = match.running_leaf
        else
            -- disagree on right
            running_leaf = match.running_leaf + 1
        end

        local agree_state, agree_state_proof
        if running_leaf:iszero() then
            agree_state, agree_state_proof = commitment.implicit_hash, {}
        else
            agree_state, agree_state_proof = commitment:prove_leaf(running_leaf - 1)
        end

        if match.tournament.level == (match.tournament.max_level - 1) then
            helper.log_timestamp(string.format(
                "seal leaf match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment.root_hash
            ))
            local ok, e = self.sender:tx_seal_leaf_match(
                match.tournament.address,
                match.commitment_one,
                match.commitment_two,
                left,
                right,
                agree_state,
                agree_state_proof
            )
            if not ok then
                helper.log_timestamp(string.format(
                    [[seal leaf match reverted: %s, current left: %s, current right: %s,
                    my left: %s, my right: %s, agree_state: %s]],
                    e, match.current_left, match.current_right, left, right, agree_state
                ))
                for i = 1, #agree_state_proof do
                    helper.log_timestamp(agree_state_proof[i])
                end
            end
        else
            helper.log_timestamp(string.format(
                "seal inner match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment.root_hash
            ))
            local ok, e = self.sender:tx_seal_inner_match(
                match.tournament.address,
                match.commitment_one,
                match.commitment_two,
                left,
                right,
                agree_state,
                agree_state_proof
            )
            if not ok then
                helper.log_timestamp(string.format(
                    [[seal inner match reverted: %s, current left: %s, current right: %s,
                    my left: %s, my right: %s, agree_state: %s]],
                    e, match.current_left, match.current_right, left, right, agree_state
                ))
                for i = 1, #agree_state_proof do
                    helper.log_timestamp(agree_state_proof[i])
                end
            end
        end
    else
        -- match running
        local found, left, right = match.current_other_parent:children()
        if not found then
            helper.log_timestamp("not my turn to react")
            return
        end

        local new_left, new_right
        if left ~= match.current_left then
            local f
            f, new_left, new_right = left:children()
            assert(f)

            helper.log_timestamp("going down to the left")
        else
            local f
            f, new_left, new_right = right:children()
            assert(f)

            helper.log_timestamp("going down to the right")
        end

        helper.log_timestamp(string.format(
            "advance match with current height %d in tournament %s of level %d for commitment %s",
            match.current_height,
            match.tournament.address,
            match.tournament.level,
            commitment.root_hash
        ))
        local ok, e = self.sender:tx_advance_match(
            match.tournament.address,
            match.commitment_one,
            match.commitment_two,
            left,
            right,
            new_left,
            new_right
        )
        if not ok then
            helper.log_timestamp(string.format(
                [[advance match reverted: %s, current left: %s, current right: %s,
                my left: %s, my right: %s, new_left: %s, new_right: %s]],
                e, match.current_left, match.current_right, left, right, new_left, new_right
            ))
        end
    end
end

function HonestStrategy:_react_tournament(tournament, log)
    helper.log_timestamp("Enter tournament at address: " .. tournament.address)
    local commitment = self.commitment_builder:build(
        tournament.base_big_cycle,
        tournament.level,
        tournament.log2_stride,
        tournament.log2_stride_count
    )

    table.insert(log.tournaments, tournament)
    table.insert(log.commitments, commitment)

    local tournament_winner = tournament.tournament_winner
    if tournament_winner.has_winner then
        if not tournament.parent then
            helper.log_timestamp("TOURNAMENT FINISHED, HURRAYYY")
            helper.log_timestamp("Winner commitment: " .. tournament_winner.commitment:hex_string())
            helper.log_timestamp("Final state: " .. tournament_winner.final:hex_string())
            log.finished = true
        else
            local old_commitment = self.commitment_builder:build(
                tournament.parent.base_big_cycle,
                tournament.parent.level,
                tournament.parent.log2_stride,
                tournament.parent.log2_stride_count
            )
            if tournament_winner.commitment ~= old_commitment.root_hash then
                helper.log_timestamp("player lost tournament")
                log.finished = true
                return
            end

            helper.log_timestamp(string.format(
                "win tournament %s of level %d for commitment %s",
                tournament.address,
                tournament.level,
                commitment.root_hash
            ))
            local _, left, right = old_commitment:children(old_commitment.root_hash)
            local ok, e = self.sender:tx_win_inner_match(
                tournament.parent.address,
                tournament.address,
                left,
                right
            )
            if not ok then
                helper.log_timestamp(string.format(
                    "win inner match reverted: %s",
                    e
                ))
            end
            return
        end
    end

    if not tournament.commitments[commitment.root_hash] then
        self:_join_tournament(tournament, commitment)
    else
        local commitment_clock = tournament.commitments[commitment.root_hash].status.clock
        helper.log_timestamp(tostring(commitment_clock))

        local latest_match = tournament.commitments[commitment.root_hash].latest_match
        log.latest_match = latest_match
        if latest_match then
            return self:_react_match(latest_match, commitment, log)
        else
            helper.log_timestamp(string.format("no match found for commitment: %s", commitment.root_hash))
        end
    end
end

function HonestStrategy:react(tournament)
    local tx_count = self.sender.tx_count
    local log = {
        commitments = {},
        tournaments = {},
        latest_match = false,
        finished = false,
    }

    self:_react_tournament(tournament, log)
    log.idle = tx_count == self.sender.tx_count


    if self.gc_strategy then
        self.gc_strategy:react(tournament)
    end

    return log
end

return HonestStrategy
