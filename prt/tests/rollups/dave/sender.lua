local Hash = require "cryptography.hash"
local MerkleTree = require "cryptography.merkle_tree"
local blockchain_constants = require "blockchain.constants"
local blockchain_utils = require "blockchain.utils"

local function quote_args(args, not_quote)
    local quoted_args = {}
    for _, v in ipairs(args) do
        if type(v) == "table" and (getmetatable(v) == Hash or getmetatable(v) == MerkleTree) then
            if not_quote then
                table.insert(quoted_args, v:hex_string())
            else
                table.insert(quoted_args, '"' .. v:hex_string() .. '"')
            end
        elseif type(v) == "table" then
            if v._tag == "tuple" then
                local qa = quote_args(v, true)
                local ca = table.concat(qa, ",")
                local sb = "'(" .. ca .. ")'"
                table.insert(quoted_args, sb)
            else
                local qa = quote_args(v, true)
                local ca = table.concat(qa, ",")
                local sb = "'[" .. ca .. "]'"
                table.insert(quoted_args, sb)
            end
        elseif not_quote then
            table.insert(quoted_args, tostring(v))
        else
            table.insert(quoted_args, '"' .. v .. '"')
        end
    end

    return quoted_args
end


local Sender = {}
Sender.__index = Sender

function Sender:new(input_box_address, app_contract_address, pk, endpoint)
    pk = pk or blockchain_constants.pks[1]
    endpoint = endpoint or blockchain_constants.endpoint
    local sender = {
        pk = pk,
        endpoint = endpoint,

        input_box_address = input_box_address,
        app_contract_address = app_contract_address,
        tx_count = 0,
    }

    setmetatable(sender, self)
    return sender
end

local cast_send_template = [[
cast send --private-key "%s" --rpc-url "%s" "%s" "%s" %s 2>&1
]]

function Sender:_send_tx(contract_address, sig, args)
    local quoted_args = quote_args(args)
    local args_str = table.concat(quoted_args, " ")

    local cmd = string.format(
        cast_send_template,
        self.pk,
        self.endpoint,
        contract_address,
        sig,
        args_str
    )

    local handle = io.popen(cmd)
    assert(handle)

    local ret = handle:read "*a"
    if ret:find "Error" then
        handle:close()
        error(string.format("Send transaction `%s` reverted:\n%s", cmd, ret))
    end

    self.tx_count = self.tx_count + 1
    handle:close()
end

function Sender:tx_add_input(payload)
    local sig = [[addInput(address,bytes)(bytes32)]]
    return self:_send_tx(
        self.input_box_address,
        sig,
        { self.app_contract_address, payload }
    )
end

function Sender:tx_add_inputs(inputs)
    for _,payload in ipairs(inputs) do
        self:advance_blocks(1)
        self:tx_add_input(payload)
        self:advance_blocks(1)
    end
end

function Sender:advance_blocks(blocks)
    blockchain_utils.advance_time(blocks, self.endpoint)
end

return Sender
