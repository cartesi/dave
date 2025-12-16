require "setup_path"

local uint256 = require "utils.bint" (256)
local Hash = require "cryptography.hash"
local env = require "test_env"

local ERC20_PORTAL_ADDRESS = assert(os.getenv("ERC20_PORTAL"))
local ERC20_TOKEN_ADDRESS = assert(os.getenv("ERC20_TOKEN"))
local ERC20_AMOUNT = "1" .. string.rep("0", 18) -- 10^18

-- Main Execution
env.spawn_blockchain {}

-- Helper routine for calling functions that returns exactly one uint256 value
local call1 = function (...)
    local ret = env.reader:_call(...)
    assert(type(ret) == "table", "Expected a table")
    local str = assert(ret[1], "Expected a non-empty array")
    assert(type(str) == "string", "Expected a string")
    local num = assert(str:match"(%d+)", "Expected a decimal number")
    return assert(uint256.new(num), "Expected a uint256 value")
end

local first_epoch = assert(env.reader:read_epochs_sealed()[1])
assert(first_epoch.input_upper_bound == 0) -- there's no input for epoch 0!

-- Derive wallet address from private key
local wallet_address = env.sender:wallet_address()

local get_wallet_balance = function ()
    return call1(
        ERC20_TOKEN_ADDRESS,
        "balanceOf(address)(uint256)",
        {wallet_address}
    )
end

-- Get wallet ERC-20 balance before minting
local initial_wallet_balance = get_wallet_balance()

-- Mint ERC-20 tokens
env.sender:_send_tx(
    ERC20_TOKEN_ADDRESS,
    "mint(uint256)",
    {ERC20_AMOUNT}
)

assert(
    get_wallet_balance() == initial_wallet_balance + ERC20_AMOUNT,
    "Wallet balance has not been incremented by minted token amount after minting"
)

local get_portal_allowance = function ()
    return call1(
        ERC20_TOKEN_ADDRESS,
        "allowance(address,address)(uint256)",
        {wallet_address, ERC20_PORTAL_ADDRESS}
    )
end

-- Get ERC-20 portal allowance before approval
local initial_portal_allowance = get_portal_allowance()

-- Approve ERC-20 portal to transfer ERC-20 tokens
env.sender:_send_tx(
    ERC20_TOKEN_ADDRESS,
    "approve(address,uint256)",
    {ERC20_PORTAL_ADDRESS, ERC20_AMOUNT}
)

assert(
    get_portal_allowance() == initial_portal_allowance + ERC20_AMOUNT,
    "ERC-20 portal allowance has not been incremented by minted token amount after approval"
)

-- Deposit ERC-20 tokens into app
-- (This makes the portal send an input to the app)
env.sender:_send_tx(
    ERC20_PORTAL_ADDRESS,
    "depositERC20Tokens(address,address,uint256,bytes)",
    {ERC20_TOKEN_ADDRESS, env.app_address, ERC20_AMOUNT, "0x"}
)

assert(
    get_wallet_balance() == initial_wallet_balance,
    "Wallet balance has not gone back to its initial value after deposit"
)

assert(
    get_portal_allowance() == initial_portal_allowance,
    "ERC-20 portal allowance has not gone back to its initial value after deposit"
)

local get_input_count = function ()
    return call1(
        env.input_box_address,
        "getNumberOfInputs(address)(uint256)",
        {env.app_address}
    )
end

-- Get input count before withdrawal request
local initial_input_count = get_input_count()

-- Request withdrawal
env.sender:tx_add_input("0x")

assert(
    get_input_count() == initial_input_count + uint256.new(1),
    "Input count has not been incremented by 1 after withdrawal request"
)

-- Spawn Dave node
env.spawn_node()

-- advance such that epoch 0 is finished
local sealed_epoch = env.roll_epoch()

-- run epoch 1
env.run_epoch(sealed_epoch, {
    -- ustep + reset
    { hash = Hash.zero, meta_cycle = 1 << 44 }
}, {})
