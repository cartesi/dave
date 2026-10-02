local Context = require "player.context"
local Dispatcher = require "player.dispatcher"
local Domain = require "player.domain"
local Fulfiller = require "player.fulfiller"
local Planner = require "player.planner"
local helper = require "utils.helper"

-- Production semantic client orchestration:
-- observe, assemble, plan, fulfill, and dispatch at most one mutation.
local Actor = {}
Actor.__index = Actor

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function state_coordinate(state)
    if state._tag == Domain.LiveMatchState.BISECTING
        or state._tag == Domain.LiveMatchState.READY_TO_SEAL_LEAF
        or state._tag == Domain.LiveMatchState.READY_TO_DELEGATE
    then
        return state.coordinate, state.remaining_height
    end
    return state.divergence.coordinate, 0
end

-- Preserve the small legacy state surface used by the e2e harness while the
-- production decision path consumes only semantic snapshots.
local function compatibility_state(dispute)
    local states = {}
    for _, folded in ipairs(dispute.fold:tournaments()) do
        local observation = dispute.observations[folded.address]
        if observation then
            local descriptor = observation.descriptor
            states[folded.address] = {
                address = folded.address,
                base_cycle = descriptor.base_cycle,
                level = descriptor.level,
                log2_stride = descriptor.log2_stride,
                log2_stride_count = descriptor.height,
                parent = nil,
                commitments = {},
                matches = {},
                tournament_winner = {},
            }
        end
    end

    for _, folded in ipairs(dispute.fold:tournaments()) do
        local state = states[folded.address]
        local observation = dispute.observations[folded.address]
        if state and observation then
            if folded.parent then
                state.parent = states[folded.parent.tournament]
            end
            for root, commitment in pairs(folded.commitments) do
                state.commitments[root] = {
                    final_state = commitment.final_state,
                    latest_match = commitment.latest_match,
                }
            end
            for index, match in ipairs(folded.matches) do
                if match.deleted then
                    state.matches[index] = false
                else
                    local observed = assert(
                        observation.matches[match.id_hash],
                        "compatibility state is missing a live observed match"
                    )
                    local semantic = observed.live.state
                    local coordinate, height = state_coordinate(semantic)
                    local legacy = {
                        tournament = state,
                        match_id_hash = match.id_hash,
                        commitment_one = match.id.commitment_one,
                        commitment_two = match.id.commitment_two,
                        current_height = height,
                        running_leaf = coordinate.leaf_position,
                        leaf_cycle = coordinate.cycle,
                        inner_tournament =
                            match.inner_tournament
                            and states[match.inner_tournament]
                            or nil,
                    }
                    if semantic._tag == Domain.LiveMatchState.BISECTING
                        or semantic._tag
                            == Domain.LiveMatchState.READY_TO_SEAL_LEAF
                        or semantic._tag
                            == Domain.LiveMatchState.READY_TO_DELEGATE
                    then
                        legacy.current_other_parent =
                            semantic.revealing_parent
                        legacy.current_left =
                            semantic.waiting_children.left
                        legacy.current_right =
                            semantic.waiting_children.right
                    end
                    state.matches[index] = legacy
                end
            end

            local standing = observation.standing
            if standing._tag == Domain.TournamentStanding.ROOT_WINNER then
                state.tournament_winner = {
                    has_winner = true,
                    commitment = standing.commitment,
                    final = standing.final_state,
                }
            elseif standing._tag
                == Domain.TournamentStanding.INNER_WINNER
            then
                state.tournament_winner = {
                    has_winner = true,
                    commitment = standing.parent_commitment,
                    dangling_commitment = standing.child_commitment,
                }
            else
                state.tournament_winner = { has_winner = false }
            end
        end
    end
    return assert(states[dispute.fold:root()],
        "root tournament is missing from compatibility state")
end

function Actor.new(args)
    args = required(args, "actor arguments")
    return setmetatable({
        reader = required(args.reader, "semantic reader"),
        commitment_builder =
            required(args.commitment_builder, "commitment builder"),
        machine_path = required(args.machine_path, "machine path"),
        inputs = required(args.inputs, "machine inputs"),
        sender = required(args.sender, "sender"),
        root_initial_hash = args.root_initial_hash,
        machine_logs = args.machine_logs,
        allow_invalid_claims = args.allow_invalid_claims == true,
    }, Actor)
end

local function report_revert(actor, action, error_message)
    helper.log_full(
        actor.sender.index,
        string.format("%s reverted: %s", action, tostring(error_message))
    )
end

function Actor:react()
    local before = self.sender.tx_count or 0
    local dispute = self.reader:fetch()
    local context = Context.assemble {
        fold = dispute.fold,
        observations = dispute.observations,
        commitment_builder = self.commitment_builder,
        root_initial_hash = self.root_initial_hash,
    }
    local decision = Planner.plan(context.snapshot)
    local log = {
        commitments = {},
        tournaments = {},
        latest_match = false,
        finished = false,
        has_lost = false,
        state = compatibility_state(dispute),
        decision = decision,
        context = context,
        head = dispute.head,
    }

    if decision._tag == Domain.HeroDecision.ACT then
        local options = {
            machine_path = self.machine_path,
            inputs = self.inputs,
            machine_logs = self.machine_logs,
            allow_invalid_claims = self.allow_invalid_claims,
        }
        local action =
            Fulfiller.prepare(decision.intent, context, options)
        local ok, error_message = Dispatcher.dispatch(action, self.sender)
        if not ok then
            report_revert(self, action._tag, error_message)
        end
    elseif decision._tag ~= Domain.HeroDecision.WAIT then
        assert(decision._tag == Domain.HeroDecision.TERMINAL,
            "unknown Hero decision")
        log.finished = true
        log.has_lost = decision.result ~= Domain.HeroTerminal.WON
        if decision.result == Domain.HeroTerminal.WON then
            helper.log_full(self.sender.index, "TOURNAMENT FINISHED")
        elseif decision.result == Domain.HeroTerminal.LOST then
            helper.log_full(self.sender.index, "player lost tournament")
        else
            helper.log_full(
                self.sender.index,
                "tournament finished without a winner"
            )
        end
    end

    log.idle = before == (self.sender.tx_count or 0)
    return log
end

Actor.compatibility_state = compatibility_state

return Actor
