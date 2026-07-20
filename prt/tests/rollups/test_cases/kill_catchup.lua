require "setup_path"

local env = require "test_env"

-- B2 catch-up kill (docs/plans/characterization.md): SIGKILL the node
-- while the machine-runner is processing the epoch's inputs, respawn,
-- and require the resumed run to produce the settlement the oracle
-- expects. No sybil: the subject is input-processing resume, WAL
-- recovery in the main database, and snapshot bookkeeping.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Add 3 inputs to epoch 1
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn Dave node, and kill it the moment it starts chewing on epoch
-- 1's first input. Gap 1 pinned: the harness default is 2, and this
-- scenario keeps the degenerate every-input-is-a-boundary case
-- covered (its batched sibling runs gap 3).
env.spawn_node(1)
env.dave_node:wait_log("processing input 1:0")
env.dave_node:kill()
env.dave_node:respawn()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- epoch_settlement cross-checks the resumed node's snapshot, inputs,
-- and commitment against the oracle lineage: identical settlement info
-- or bust. No dispute needed.
env.epoch_settlement(sealed_epoch)
print "[kill_catchup] resumed node settled identically to the oracle"
