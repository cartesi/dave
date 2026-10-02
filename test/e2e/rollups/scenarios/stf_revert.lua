require "setup_path"

local env = require "test_env"

-- The last state-transition shape stf_all cannot pin statically: the
-- full revert restore. When an input is rejected, the closing slot of
-- the big cycle where it yielded resets the uarch and substitutes the
-- recorded revert root; that slot's
-- position depends on how long the program ran, so the oracle reports
-- each input's big-cycle count and the patch chain is computed from
-- it. Meant for the yield program, which rejects every input.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- Steer the dispute onto input 0's revert: the reject yield happened in
-- big cycle (bigs - 1) of window 0, so the revert is the closing slot
-- ending at meta-cycle bigs * 2^20, i.e. transition bigs * 2^20 - 1.
env.run_steered_epoch(sealed_epoch, function(settlement)
    local bigs = assert(settlement.processing_bigs[1], "no input processed")
    print(string.format("[stf_revert] revert slot ends at big cycle %d", bigs))
    return (bigs << 20) - 1
end, {})

print "[stf_revert] dispute over the revert transition won"
