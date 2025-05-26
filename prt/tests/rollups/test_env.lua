local Blockchain = require "blockchain.node"
local Dave = require "dave.node"
local Machine = require "computation.machine"
local time = require "utils.time"
local Reader = require "dave.reader"
local Sender = require "dave.sender"

-- anvil deployment state dump
local ANVIL_PATH = assert(os.getenv("ANVIL_PATH"))

-- machine template hash
local TEMPLATE_MACHINE = assert(os.getenv("TEMPLATE_MACHINE"))

-- addresses
local APP_ADDRESS = assert(os.getenv("APP"))
local CONSENSUS_ADDRESS = assert(os.getenv("CONSENSUS"))
local INPUT_BOX_ADDRESS = assert(os.getenv("INPUT_BOX"))

local SLEEP_TIME = 1
local FAST_FORWARD_TIME = 32


local ECHO_MSG = "0x48656c6c6f2076726f6d204461766521"
-- Encoded Input blob
-- 31337
-- 0x0000000000000000000000000000000000000000
-- 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
-- 1
-- 0
-- 1
-- 0
-- "0x48656c6c6f2076726f6d204461766521"
-- cast abi-encode "EvmAdvance(uint256,address,address,uint256,uint256,uint256,uint256,bytes)" 31337 "0x0000000000000000000000000000000000000000" "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" 1 1622547800 1 0 "0x48656c6c6f2076726f6d204461766521"
-- local ENCODED_INPUT =
-- "0x0000000000000000000000000000000000000000000000000000000000007a690000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb9226600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000060b61d58000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000001048656c6c6f2076726f6d20446176652100000000000000000000000000000000"


local Env = {
    anvil_path = ANVIL_PATH,

    app_address = APP_ADDRESS,
    consensus_address = CONSENSUS_ADDRESS,
    input_box_address = INPUT_BOX_ADDRESS,
    template_machine = TEMPLATE_MACHINE,

    sleep_time = SLEEP_TIME,
    fast_forward_time = FAST_FORWARD_TIME,

    sample_inputs = { ECHO_MSG },

    -- blockchain = false,
    -- reader = false,
    -- sender = false,

    -- dave_node = false,
}


function Env.spawn_blockchain()
    local blockchain = Blockchain:new(ANVIL_PATH, INPUT_BOX_ADDRESS, APP_ADDRESS, CONSENSUS_ADDRESS)
    Env.blockchain = blockchain
    Env.reader = Reader:new(INPUT_BOX_ADDRESS, CONSENSUS_ADDRESS, blockchain.endpoint)
    Env.sender = Sender:new(INPUT_BOX_ADDRESS, APP_ADDRESS, blockchain.pks[1], blockchain.endpoint)
    Env.sender:advance_blocks(32)
    return blockchain
end

function Env.spawn_node()
    local dave_node = Dave:new(TEMPLATE_MACHINE, APP_ADDRESS, Env.sender, SLEEP_TIME)
    Env.dave_node = dave_node
    return dave_node
end

function Env.roll_epoch()
    assert(Env.blockchain, "blockchain not spawned")
    local epochs = Env.reader:read_epochs_sealed()
    local target_epoch = #epochs + 1

    -- TODO verify (and wait otherwise) whether node makes claim in tournament.
    -- Currently we hope the sleep inside spawn is enough.
    Env.sender:advance_blocks(3000) -- TODO improve magic number
    time.sleep_until(function()
        epochs = Env.reader:read_epochs_sealed()
        if #epochs >= target_epoch then
            assert(#epochs == target_epoch)
            return true
        else
            return false
        end
    end)

    Env.sender:advance_blocks(32)
    return assert(epochs[target_epoch])
end

function Env.wait_until_epoch(target_epoch)
    local total_epochs = target_epoch + 1
    local epochs
    time.sleep_until(function()
        epochs = Env.reader:read_epochs_sealed()
        if #epochs >= total_epochs then
            assert(#epochs == total_epochs)
            return true
        else
            Env.sender:advance_blocks(Env.fast_forward_time * 4)
            return false
        end
    end)
    return assert(epochs[total_epochs])
end

-- returns the machine_path, inputs, initial_state, and commitment
function Env.epoch_settlement(sealed_epoch)
    -- get all inputs
    local all_inputs = Env.reader:read_inputs_added(sealed_epoch.epoch_number)

    -- slice inputs into `sealed_epoch` inputs
    local inputs = {}
    for i = sealed_epoch.input_lower_bound + 1, sealed_epoch.input_upper_bound do
        table.insert(inputs, all_inputs[i].data)
    end

    -- sanity check: read node inputs and assert they are the same
    local node_inputs = Env.dave_node:inputs(sealed_epoch.epoch_number)
    assert(#node_inputs == #inputs)
    for k, v in ipairs(inputs) do
        assert(string.upper(v) == string.upper(node_inputs[k]))
    end

    -- Get `sealed_epoch` machine path.
    local machine_path = assert(Env.dave_node:machine_path(sealed_epoch.epoch_number))

    -- Compute honest commitment
    -- 44 is the initial log2_stride currently configured in the smart contracts.
    local initial_state, commitment = Machine.root_rollup_commitment(machine_path, 44, inputs)
    assert(sealed_epoch.initial_machine_state_hash, initial_state)

    -- sanity check: read node commitment and assert they are the same
    local node_initial_state, node_commitment = Env.dave_node:root_commitment(sealed_epoch.epoch_number)
    assert(initial_state == node_initial_state.root_hash)
    assert(commitment == node_commitment)

    return {
        machine_path = machine_path,
        inputs = inputs,
        initial_state = initial_state,
        commitment = commitment,
    }
end

function Env.drive_player(player_coroutine)
    repeat
        local success, log = coroutine.resume(player_coroutine)
        assert(success, string.format("player fail to resume with error: %s", log))

        if log.has_lost then
            print(string.format("Player has lost, bailing"))
            return "lost"
        end

        time.sleep(Env.sleep_time)
    until coroutine.status == "dead"
    return "dead"
end

return Env
