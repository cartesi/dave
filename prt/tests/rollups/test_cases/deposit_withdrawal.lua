require "setup_path"

local Hash = require "cryptography.hash"
local env = require "test_env"

local ERC20_PORTAL_ADDRESS = assert(os.getenv("ERC20_PORTAL"))
local ERC20_TOKEN_ADDRESS = assert(os.getenv("ERC20_TOKEN"))
local ERC20_AMOUNT = "1" .. string.rep("0", 18) -- 10^18

-- Main Execution
env.spawn_blockchain {}
local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there's no input for epoch 0!

-- Mint ERC-20 tokens
env.sender:_send_tx(
    ERC20_TOKEN_ADDRESS,
    "mint(uint256)",
    {ERC20_AMOUNT}
)

-- Approve ERC-20 portal to transfer ERC-20 tokens
env.sender:_send_tx(
    ERC20_TOKEN_ADDRESS,
    "approve(address,uint256)",
    {ERC20_PORTAL_ADDRESS, ERC20_AMOUNT}
)

-- Deposit ERC-20 tokens into app
-- (This makes the portal send an input to the app)
env.sender:_send_tx(
    ERC20_PORTAL_ADDRESS,
    "depositERC20Tokens(address,address,uint256,bytes)",
    {ERC20_TOKEN_ADDRESS, env.app_address, ERC20_AMOUNT, "0x"}
)

-- Request withdrawal
env.sender:tx_add_input("0x")

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {})
