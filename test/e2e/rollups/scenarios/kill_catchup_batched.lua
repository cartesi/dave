require "setup_path"

local env = require "test_env"

-- With a snapshot gap above 1, the machine-runner commits one batch
-- of inputs per transaction. This scenario aims a SIGKILL at the first
-- batch and requires the resumed node to settle identically to the
-- oracle. The kill is not guaranteed to land mid-batch: the 1 s log
-- poll is slower than one echo input, so the batch may already have
-- committed. Mid-batch atomicity rests on the unit-level
-- fault-injection tests.

-- Main Execution
env.spawn_blockchain { env.sample_inputs[1] }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- epoch 0 is empty!

-- Enough inputs for one full batch plus a partial one at gap 3.
env.sender:tx_add_inputs { env.sample_inputs[1], env.sample_inputs[1], env.sample_inputs[1] }

-- Spawn with a batch of 3; kill once the second input of the first
-- batch is reported, possibly after the batch has committed.
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
print "[kill_catchup_batched] resumed node settled identically to the oracle"
