local bint = require 'utils.bint' (256) -- use 256 bits integers
local Reader = require "player.reader"
local constants = require "computation.constants"

local StateFetcher = {}
StateFetcher.__index = StateFetcher

function StateFetcher:new(root_tournament_address, endpoint)
    local state = {
        root_tournament_address = root_tournament_address,
        reader = Reader:new(endpoint),
        hero_state = {}
    }

    setmetatable(state, self)
    return state
end

function StateFetcher:fetch()
    local root_tournament = {
        base_big_cycle = 0,
        address = self.root_tournament_address,
        max_level = false,
        level = false,
        log2_stride = false,
        log2_stride_count = false,
        parent = false,
        commitments = {},
        matches = {},
        tournament_winner = {}
    }

    return self:_fetch_tournament(root_tournament)
end

function StateFetcher:_fetch_tournament(tournament)
    local consts = self.reader:read_constants(tournament.address)
    tournament.max_level = consts.max_level
    tournament.level = consts.level
    tournament.log2_stride = consts.log2_step
    tournament.log2_stride_count = consts.height

    assert(tournament.level < tournament.max_level)

    local matches = self:_capture_matches(tournament)
    local commitments = self.reader:read_commitment_joined(tournament.address)

    for _, log in ipairs(commitments) do
        local root = log.root
        local status = self.reader:read_commitment(tournament.address, root)
        tournament.commitments[root] = { status = status, latest_match = false }
    end

    for _, match in ipairs(matches) do
        if match then
            self:_fetch_match(match)
            tournament.commitments[match.commitment_one].latest_match = match
            tournament.commitments[match.commitment_two].latest_match = match
        end
    end
    tournament.matches = matches

    if not tournament.parent then
        tournament.tournament_winner = self.reader:root_tournament_winner(tournament.address)
    else
        tournament.tournament_winner = self.reader:inner_tournament_winner(tournament.address)
    end

    return tournament
end

function StateFetcher:_fetch_match(match)
    if match.current_height == 0 then
        -- match sealed
        if match.tournament.level == (match.tournament.max_level - 1) then
            match.finished =
                self.reader:read_match(match.tournament.address, match.match_id_hash)[1]:is_zero()
        else
            local address = self.reader:read_tournament_created(
                match.tournament.address,
                match.match_id_hash
            ).new_tournament

            local new_tournament = {
                address = address,
                level = match.tournament.level + 1,
                parent = match.tournament,
                base_big_cycle = match.base_big_cycle,
                commitments = {},
            }
            match.inner_tournament = new_tournament

            return self:_fetch_tournament(new_tournament)
        end
    end
end

function StateFetcher:_capture_matches(tournament)
    local matches = self.reader:read_match_created(tournament.address)

    for k, match in ipairs(matches) do
        local m = self.reader:read_match(tournament.address, match.match_id_hash)
        if m[1]:is_zero() and m[2]:is_zero() and m[3]:is_zero() then
            matches[k] = false
        else
            match.tournament = tournament
            match.current_other_parent = m[1]
            match.current_left = m[2]
            match.current_right = m[3]
            match.running_leaf = bint(m[4])
            match.current_height = tonumber(m[5])
            match.log2_step = tonumber(m[6])
            match.height = tonumber(m[7])

            local leaf_cycle = self.reader:read_cycle(tournament.address, match.match_id_hash)
            match.leaf_cycle = bint(leaf_cycle)
            match.base_big_cycle = (match.leaf_cycle >> constants.log2_uarch_span_to_barch):touinteger()
        end
    end

    return matches
end

return StateFetcher
