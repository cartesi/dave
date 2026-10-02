local constants = require "blockchain.constants"
local Actor = require "player.actor"
local SemanticReader = require "player.semantic_reader"
local Sender = require "player.sender"

-- Each sybil signs with an account of its own, from 2 up (1 is the
-- harness sender's), skipping the node's: see blockchain.constants.
local next_account = 2

local function sybil_runner(commitment_builder, machine_path, root_tournament, inputs)
    local account, pk
    repeat
        account = next_account
        pk = assert(constants.pks[account], "no test account left for a sybil")
        next_account = next_account + 1
    until pk ~= constants.node_pk

    local actor = Actor.new {
        reader = SemanticReader.from_endpoint(root_tournament, 0, constants.endpoint),
        commitment_builder = commitment_builder,
        machine_path = machine_path,
        inputs = inputs,
        sender = Sender:new(pk, account, constants.endpoint),
        -- Patched sybils deliberately claim a wrong post-state. They still
        -- submit the locally valid proof so the contract rejects the move and
        -- the adversarial clock path remains exercised.
        allow_invalid_claims = true,
    }
    return coroutine.create(function()
        local log
        repeat
            log = actor:react()
            coroutine.yield(log)
        until log.finished
    end)
end

return sybil_runner
