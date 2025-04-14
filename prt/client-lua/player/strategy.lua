local helper = require "utils.helper"
local Machine = require "computation.machine"
local constants = require "computation.constants"
local GarbageCollector = require "player.gc"

local HonestStrategy = {}
HonestStrategy.__index = HonestStrategy

function HonestStrategy:new(commitment_builder, inputs, machine_path, sender)
    local gc_strategy = GarbageCollector:new(sender)

    local honest_strategy = {
        commitment_builder = commitment_builder,
        inputs = inputs,
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
    local f, left, right = commitment:children()
    assert(f)
    local last, proof = commitment:last()

    helper.log_full(self.sender.index, string.format(
        "join tournament %s of level %d with commitment %s",
        tournament.address,
        tournament.level,
        commitment
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

local function _is_my_turn(match, commitment)
    -- commitment one should be the first to react after the match is created
    -- thus commitment one will hold the same parity as the match height (not xor)
    -- and commitment two will hold the opposite parity (xor)
    local res
    local height_parity = match.tournament.log2_stride_count % 2 == 0
    local current_height_parity = match.current_height % 2 == 0
    local xor_of_two_parities = height_parity ~= current_height_parity

    if commitment == match.commitment_one then
        res = not xor_of_two_parities
    else
        res = xor_of_two_parities
    end

    if not res then
        helper.log_timestamp("not my turn to react to match")
    end


    return res
end

function HonestStrategy:_react_match(match, commitment, log)
    helper.log_full(self.sender.index, "Enter match at HEIGHT: " .. match.current_height)

    local opponent
    if commitment == match.commitment_one then
        opponent = match.tournament.commitments[match.commitment_two]
    else
        opponent = match.tournament.commitments[match.commitment_one]
    end

    if not opponent.status.clock:has_time() then
        local f, left, right = commitment:children()
        assert(f)

        helper.log_full(self.sender.index,
            string.format("win match by timeout in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment))

        local ok, e = self.sender:tx_win_timeout_match(
            match.tournament.address,
            match.commitment_one,
            match.commitment_two,
            left,
            right
        )
        if not ok then
            helper.log_full(self.sender.index, string.format(
                "win timeout match reverted: %s",
                e
            ))
        end
        return
    end

    if match.current_height == 0 then
        -- match sealed
        if match.tournament.level == (match.tournament.max_level - 1) then
            local f, left, right = commitment:children()
            assert(f)

            helper.log_full(self.sender.index, string.format(
                "Calculating access logs for step %s",
                match.running_leaf
            ))

            local meta_cycle = match.leaf_cycle
            local logs = Machine.get_logs(self.machine_path, match.current_other_parent, meta_cycle, self.inputs,
                self.commitment_builder.snapshot_dir)

            helper.log_full(self.sender.index, string.format(
                "win leaf match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment
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
                helper.log_full(self.sender.index, string.format(
                    "win leaf match reverted: %s",
                    e
                ))
            end
        elseif match.inner_tournament then
            return self:_react_tournament(match.inner_tournament, log)
        end
    elseif match.current_height == 1 then
        -- match to be sealed
        if not _is_my_turn(match, commitment) then return end
        local found, left, right = match.current_other_parent:children()
        assert(found)

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
            helper.log_full(self.sender.index, string.format(
                "seal leaf match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment
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
                helper.log_full(self.sender.index, string.format(
                    [[seal leaf match reverted: %s, current left: %s, current right: %s,
                    my left: %s, my right: %s, agree_state: %s]],
                    e, match.current_left, match.current_right, left, right, agree_state
                ))
                for i = 1, #agree_state_proof do
                    helper.log_full(self.sender.index, agree_state_proof[i])
                end
            end
        else
            helper.log_full(self.sender.index, string.format(
                "seal inner match in tournament %s of level %d for commitment %s",
                match.tournament.address,
                match.tournament.level,
                commitment
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
                helper.log_full(self.sender.index, string.format(
                    [[seal inner match reverted: %s, current left: %s, current right: %s,
                    my left: %s, my right: %s, agree_state: %s]],
                    e, match.current_left, match.current_right, left, right, agree_state
                ))
                for i = 1, #agree_state_proof do
                    helper.log_full(self.sender.index, agree_state_proof[i])
                end
            end
        end
    else
        -- match running
        if not _is_my_turn(match, commitment) then return end
        local found, left, right = match.current_other_parent:children()
        assert(found)

        local new_left, new_right
        if left ~= match.current_left then
            local f
            f, new_left, new_right = left:children()
            assert(f)

            helper.log_full(self.sender.index, "going down to the left")
        else
            local f
            f, new_left, new_right = right:children()
            assert(f)

            helper.log_full(self.sender.index, "going down to the right")
        end

        helper.log_full(self.sender.index, string.format(
            "advance match with current height %d in tournament %s of level %d for commitment %s",
            match.current_height,
            match.tournament.address,
            match.tournament.level,
            commitment
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
            helper.log_full(self.sender.index, string.format(
                [[advance match reverted: %s, current left: %s, current right: %s,
                my left: %s, my right: %s, new_left: %s, new_right: %s]],
                e, match.current_left, match.current_right, left, right, new_left, new_right
            ))
        end
    end
end

function HonestStrategy:_react_tournament(tournament, log)
    helper.log_full(self.sender.index, "Enter tournament at address: " .. tournament.address)
    local commitment = self.commitment_builder:build(
        tournament.base_big_cycle,
        tournament.level,
        tournament.log2_stride,
        tournament.log2_stride_count,
        self.inputs
    )

    table.insert(log.tournaments, tournament)
    table.insert(log.commitments, commitment)

    local tournament_winner = tournament.tournament_winner
    if tournament_winner.has_winner then
        if not tournament.parent then
            helper.log_full(self.sender.index, "TOURNAMENT FINISHED, HURRAYYY")
            helper.log_full(self.sender.index, "Winner commitment: " .. tournament_winner.commitment:hex_string())
            helper.log_full(self.sender.index, "Final state: " .. tournament_winner.final:hex_string())
            log.finished = true
        else
            local old_commitment = self.commitment_builder:build(
                tournament.parent.base_big_cycle,
                tournament.parent.level,
                tournament.parent.log2_stride,
                tournament.parent.log2_stride_count,
                self.inputs
            )
            if tournament_winner.commitment ~= old_commitment then
                helper.log_full(self.sender.index, "player lost tournament")
                log.finished = true
                return
            end

            helper.log_full(self.sender.index, string.format(
                "win tournament %s of level %d for commitment %s",
                tournament.address,
                tournament.level,
                commitment
            ))
            local _, left, right = old_commitment:children()
            local ok, e = self.sender:tx_win_inner_match(
                tournament.parent.address,
                tournament.address,
                left,
                right
            )
            if not ok then
                helper.log_full(self.sender.index, string.format(
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
        helper.log_full(self.sender.index, tostring(commitment_clock))

        local latest_match = tournament.commitments[commitment.root_hash].latest_match
        log.latest_match = latest_match
        if latest_match then
            return self:_react_match(latest_match, commitment, log)
        else
            helper.log_full(self.sender.index, string.format("no match found for commitment: %s", commitment))
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
