require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

local CONFIG_ERC20_PORTAL_ADDRESS = "ACA6586A0Cf05bD831f2501E7B4aea550dA6562D"
local CONFIG_ERC20_WITHDRAWAL_ADDRESS = "70997970C51812dc3A010C7d01b50e0d17dc79C8"
local CONFIG_ERC20_TOKEN_ADDRESS = "c6e7DF5E7b4f2A278906862b61205850344D4e7d"
local ETH10K = "0x21e19e0c9bab2400000"

local function exec(fmt, ...)
    local cmd = string.format(fmt, ...)
    local reader = io.popen(cmd)
    assert(reader, "`popen` returned nil reader")

    local data = reader:read("*a")
    local success, _, code = reader:close()
    assert(success, string.format("command [[%s]] failed on close:\n%d", cmd, code))

    return data:gsub("\n$", "") -- remove trailing newline from data
end

local function set_balance(endpoint, account, value)
    return exec([[cast rpc -r "%s" anvil_setBalance "%s" "%s"]], endpoint, account, value)
end

local function auto_impersonate(endpoint, yes)
    return exec([[cast rpc -r "%s" anvil_autoImpersonateAccount %s]], endpoint, yes)
end

local deposit_payload = exec(
	[[cast abi-encode --packed '(address,address,uint256,bytes)' "%s" "%s" "%s" "%s"]],
	CONFIG_ERC20_TOKEN_ADDRESS,
	CONFIG_ERC20_PORTAL_ADDRESS,
	"1000", "0x"
)

local valid_deposit_inpuit = { sender = CONFIG_ERC20_PORTAL_ADDRESS, payload = deposit_payload }
local invalid_deposit_input = { sender = CONFIG_ERC20_WITHDRAWAL_ADDRESS, payload = deposit_payload }
local withdrawal_input = { sender = CONFIG_ERC20_WITHDRAWAL_ADDRESS, payload = "0x" }

-- Main Execution
env.spawn_blockchain()

-- Spawn Dave node
env.spawn_node()

-- add inputs to epoch 1
auto_impersonate(env.blockchain.endpoint, "true")
set_balance(env.blockchain.endpoint, CONFIG_ERC20_PORTAL_ADDRESS, ETH10K)
env.sender:tx_add_inputs{valid_deposit_inpuit, invalid_deposit_input, withdrawal_input}
auto_impersonate(env.blockchain.endpoint, "false")

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
sealed_epoch = env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
})
-- 
-- -- run epoch 2
-- sealed_epoch = env.run_epoch(sealed_epoch, {
--     -- ustep + reset
--     { hash = Hash.zero, meta_cycle = 1 << 44 }
-- })
