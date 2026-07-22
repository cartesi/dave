local Domain = require "player.domain"
local Fulfiller = require "player.fulfiller"

-- The only effectful dispatch seam for semantic Hero/GC plans.
--
-- Each branch performs exactly one Sender mutation. Error handling belongs to
-- the actor and must never select a second verb from the same observation.
local Dispatcher = {}

function Dispatcher.dispatch(action, sender)
    local tag = action._tag
    if tag == Fulfiller.PreparedAction.JOIN then
        return sender:tx_join_tournament(
            action.tournament,
            action.final_state,
            action.proof,
            action.left,
            action.right
        )
    end
    if tag == Fulfiller.PreparedAction.CLAIM_TIMEOUT then
        return sender:tx_win_timeout_match(
            action.tournament,
            action.match_id.commitment_one,
            action.match_id.commitment_two,
            action.left,
            action.right
        )
    end
    if tag == Fulfiller.PreparedAction.ADVANCE then
        return sender:tx_advance_match(
            action.tournament,
            action.match_id.commitment_one,
            action.match_id.commitment_two,
            action.left,
            action.right,
            action.new_left,
            action.new_right
        )
    end
    if tag == Fulfiller.PreparedAction.SEAL_LEAF then
        return sender:tx_seal_leaf_match(
            action.tournament,
            action.match_id.commitment_one,
            action.match_id.commitment_two,
            action.left,
            action.right,
            action.agree_state,
            action.proof
        )
    end
    if tag == Fulfiller.PreparedAction.CREATE_CHILD then
        return sender:tx_seal_inner_match(
            action.tournament,
            action.match_id.commitment_one,
            action.match_id.commitment_two,
            action.left,
            action.right,
            action.agree_state,
            action.proof
        )
    end
    if tag == Fulfiller.PreparedAction.PROVE_LEAF then
        return sender:tx_win_leaf_match(
            action.tournament,
            action.match_id.commitment_one,
            action.match_id.commitment_two,
            action.left,
            action.right,
            action.proof
        )
    end
    if tag == Fulfiller.PreparedAction.PROPAGATE_CHILD then
        return sender:tx_win_inner_match(
            action.parent_tournament,
            action.child_tournament,
            action.left,
            action.right
        )
    end
    error("unknown prepared Hero action " .. tostring(tag), 2)
end

function Dispatcher.dispatch_gc(intent, sender)
    if intent._tag == Domain.GcIntent.ELIMINATE_MATCH then
        return sender:eliminate_match(
            intent.tournament,
            intent.match_id.commitment_one,
            intent.match_id.commitment_two
        )
    end
    if intent._tag == Domain.GcIntent.ELIMINATE_CHILD then
        return sender:eliminate_inner_tournament(
            intent.parent_tournament,
            intent.child_tournament
        )
    end
    error("unknown GC intent " .. tostring(intent._tag), 2)
end

return Dispatcher
