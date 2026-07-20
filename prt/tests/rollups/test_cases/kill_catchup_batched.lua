require "setup_path"

local env = require "test_env"

-- The batched sibling of kill_catchup (B2): with a snapshot gap above
-- 1 the machine-runner commits one batch of inputs per transaction
-- (storage v2, docs/plans/node-refactor.md workstream 3/7), so a
-- SIGKILL mid-batch drops the uncommitted records entirely and the
-- resumed run re-executes the whole batch. The oracle comparison
-- proves the replay reproduces identical rows - the e2e counterpart
-- of the unit-level fault-injection atomicity test. The harness
-- default is gap 2 (small batches everywhere); this scenario's
-- larger gap is what puts a full multi-record batch plus a partial
-- one under the kill.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Enough inputs for one full batch plus a partial one at gap 3.
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn with a batch of 3; kill while the second input of the first
-- batch is in flight, before any of its rows can have committed.
env.spawn_node(3)
env.dave_node:wait_log("processing input 1:1")
env.dave_node:kill()
env.dave_node:respawn()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- epoch_settlement cross-checks the resumed node's snapshot, inputs,
-- and commitment against the oracle lineage: identical settlement info
-- or bust. No dispute needed.
env.epoch_settlement(sealed_epoch)
print "[kill_catchup_batched] resumed node re-executed the batch and settled identically to the oracle"
