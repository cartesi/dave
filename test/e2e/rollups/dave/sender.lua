local PlayerSender = require "player.sender"
local blockchain_utils = require "blockchain.utils"

-- The harness's own account: it deploys the app, adds inputs, and mines,
-- sending through the sybil's cast transport.
local Sender = setmetatable({}, { __index = PlayerSender })
Sender.__index = Sender

function Sender:new(input_box_address, dave_app_factory_address, app_contract_address, pk, endpoint)
    local sender = PlayerSender.new(self, assert(pk), nil, assert(endpoint))
    sender.input_box_address = input_box_address
    sender.dave_app_factory_address = dave_app_factory_address
    sender.app_contract_address = app_contract_address
    return sender
end

function Sender:tx_add_input(payload)
    local sig = "addInput(address,bytes)"
    return self:_send_tx(
        self.input_box_address,
        sig,
        { self.app_contract_address, payload }
    )
end

function Sender:tx_add_inputs(inputs)
    for _,payload in ipairs(inputs) do
        self:tx_add_input(payload)
    end
end

function Sender:tx_new_dave_app(template_hash, sentries, salt)
    local sig = "newDaveApp(bytes32,uint256,address,address[],(address,uint8,uint8,uint64,address),bytes32)"
    local claim_staging_period = 1000
    local address_zero = "0x" .. string.rep("00", 20)
    local sentry_manager = address_zero
    local sentries_str = "[" .. table.concat(sentries, ",") .. "]"
    local withdrawal_config = string.format("(%s,0,0,0,%s)", address_zero, address_zero)
    return self:_send_tx(
        self.dave_app_factory_address,
        sig,
        { template_hash, claim_staging_period, sentry_manager, sentries_str, withdrawal_config, salt }
    )
end

function Sender:advance_blocks(blocks)
    blockchain_utils.advance_time(blocks, self.endpoint)
end

return Sender
