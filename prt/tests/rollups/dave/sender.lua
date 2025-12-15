local Hash = require "cryptography.hash"
local MerkleTree = require "cryptography.merkle_tree"
local blockchain_constants = require "blockchain.constants"
local blockchain_utils = require "blockchain.utils"
local bint = require 'utils.bint' (256) -- use 256-bit unsigned integers

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

function Sender:new(input_box_address, dave_app_factory_address, app_contract_address, pk, endpoint)
    pk = pk or blockchain_constants.pks[1]
    endpoint = endpoint or blockchain_constants.endpoint
    local sender = {
        pk = pk,
        endpoint = endpoint,

        input_box_address = input_box_address,
        dave_app_factory_address = dave_app_factory_address,
        app_contract_address = app_contract_address,
        tx_count = 0,
    }

    setmetatable(sender, self)
    return sender
end


local cast_send_template = [[
cast send --private-key "%s" --rpc-url "%s" --value "%s" "%s" "%s" %s 2>&1
]]

function Sender:_send_tx(destination, sig, args, value)
    value = value or bint.zero()

    local quoted_args = quote_args(args)
    local args_str = table.concat(quoted_args, " ")

    local cmd = string.format(
        cast_send_template,
        self.pk,
        self.endpoint,
        value,
        destination,
        sig,
        args_str
    )

    local handle = io.popen(cmd)
    assert(handle)

    local ret = handle:read "*a"
    if ret:find "Error" then
        handle:close()
        error(string.format("Send transaction `%s` reverted:\n%s", sig, ret))
    end

    self.tx_count = self.tx_count + 1
    handle:close()
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

function Sender:tx_new_dave_app(template_hash, salt)
    local sig = "newDaveApp(bytes32,bytes32)"
    return self:_send_tx(
        self.dave_app_factory_address,
        sig,
        { template_hash, salt }
    )
end

function Sender:tx_join_tournament(tournament_address, final_state, proof, left_child, right_child)
    local sig = [[joinTournament(bytes32,bytes32[],bytes32,bytes32)]]

    -- Get bond value by calling the view function
    local bondValueCmd = string.format(
        [[cast call --rpc-url "%s" "%s" "bondValue()(uint256)" 2>&1]],
        self.endpoint,
        tournament_address
    )

    local handle = io.popen(bondValueCmd)
    assert(handle)
    local bondValueResult = handle:read("*a")
    handle:close()

    if bondValueResult:find("Error") then
        error(string.format("Failed to get bond value: %s", bondValueResult))
    end

    -- Extract the decimal bond value directly from the result
    local bondValueDecimalStr = bondValueResult:match("(%d+)")
    if not bondValueDecimalStr then
        error("Failed to parse decimal bond value from result: " .. bondValueResult)
    end

    return pcall(
        self._send_tx,
        self,
        tournament_address,
        sig,
        { final_state, proof, left_child, right_child },
        bondValueDecimalStr
    )
end

function Sender:advance_blocks(blocks)
    blockchain_utils.advance_time(blocks, self.endpoint)
end

return Sender
