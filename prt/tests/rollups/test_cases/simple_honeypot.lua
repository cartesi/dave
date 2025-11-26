require "setup_path"
local blockchain_utils = require "blockchain.utils"

local Hash = require "cryptography.hash"
local env = require "test_env"

local CONFIG_ERC20_PORTAL_ADDRESS = "ACA6586A0Cf05bD831f2501E7B4aea550dA6562D"
local CONFIG_ERC20_WITHDRAWAL_ADDRESS = "70997970C51812dc3A010C7d01b50e0d17dc79C8"
local CONFIG_ERC20_TOKEN_ADDRESS = "c6e7DF5E7b4f2A278906862b61205850344D4e7d"

local deposit_payload = blockchain_utils.exec(
	[[cast abi-encode --packed '(address,address,uint256,bytes)' "%s" "%s" "%s" "%s"]],
	CONFIG_ERC20_TOKEN_ADDRESS,
	CONFIG_ERC20_PORTAL_ADDRESS,
	"1000", "0x"
)

local valid_deposit_inpuit = { sender = CONFIG_ERC20_PORTAL_ADDRESS, payload = deposit_payload }
local invalid_deposit_input = { sender = CONFIG_ERC20_WITHDRAWAL_ADDRESS, payload = deposit_payload }
local withdrawal_input = { sender = CONFIG_ERC20_WITHDRAWAL_ADDRESS, payload = "0x" }

-- Main Execution
env.spawn_blockchain { valid_deposit_inpuit, invalid_deposit_input, withdrawal_input }
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 3) -- there's one input for epoch 0 already!

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})
