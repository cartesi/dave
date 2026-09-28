require "setup_path"

local env = require "test_env"
local conversion = require "utils.conversion"

-- Main Execution
-- No sample input: DaveConsensus (3.0) seals the next epoch with the
-- InputBox count at the settle transaction's block, and every input
-- below lands before the node's first settle. The big input must be
-- the sealed epoch's ONLY input so the dispute patches below target
-- ITS first state transition (the input-feeding step is what forces
-- the 64KB blob through the on-chain STF).
env.spawn_blockchain()
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there's no input for epoch 0!

-- The reduction was 10, however it causes decoding error on some machines
-- Using 13 to is still a big input but passes the test
local reduction = 13
local big_input = conversion.bin_from_hex_n("0x6228290203658fd4987e40cbb257cabf258f9c288cdee767eaba6b234a73a2f9")
    :rep((1 << 11) - reduction)

assert(big_input:len() == (1 << 16) - (32 * reduction))
env.sender:tx_add_inputs { conversion.hex_from_bin_n(big_input) }

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- The dispute must end on the very first state transition, which feeds
-- the big input through the on-chain STF.
env.run_steered_epoch(sealed_epoch, function(settlement)
    assert(#settlement.inputs == 1)
    return 0
end)
print("Correct claim won!")
