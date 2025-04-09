local eth_abi = require "utils.eth_abi"

local function parse_topics(json)
    local _, _, topics = json:find(
        [==["topics":%[([^%]]*)%]]==]
    )

    local t = {}
    for k, _ in string.gmatch(topics, [["(0x%x+)"]]) do
        table.insert(t, k)
    end

    return t
end

local function parse_data(json, sig)
    local _, _, data = json:find(
        [==["data":"(0x%x+)"]==]
    )

    local decoded_data = eth_abi.decode_event_data(sig, data)
    return decoded_data
end

local function parse_meta(json)
    local _, _, block_hash = json:find(
        [==["blockHash":"(0x%x+)"]==]
    )

    local _, _, block_number = json:find(
        [==["blockNumber":"(0x%x+)"]==]
    )

    local _, _, log_index = json:find(
        [==["logIndex":"(0x%x+)"]==]
    )

    local t = {
        block_hash = block_hash,
        block_number = tonumber(block_number),
        log_index = tonumber(log_index),
    }

    return t
end


local function parse_logs(logs, data_sig)
    local ret = {}
    for k, _ in string.gmatch(logs, [[{[^}]*}]]) do
        local emited_topics = parse_topics(k)
        local decoded_data = parse_data(k, data_sig)
        local meta = parse_meta(k)
        table.insert(ret, { emited_topics = emited_topics, decoded_data = decoded_data, meta = meta })
    end

    return ret
end

local Reader = {}
Reader.__index = Reader

function Reader:new(endpoint)
    local reader = {
        endpoint = assert(endpoint)
    }

    setmetatable(reader, self)
    return reader
end

local cast_logs_template = [==[
cast rpc -r "%s" eth_getLogs \
    '[{"fromBlock": "earliest", "toBlock": "latest", "address": "%s", "topics": [%s]}]' -w  2>&1
]==]

function Reader:_read_logs(contract_address, sig, topics, data_sig)
    topics = topics or { false, false, false }
    local encoded_sig = eth_abi.encode_sig(sig)
    table.insert(topics, 1, encoded_sig)
    assert(#topics == 4, "topics doesn't have four elements")

    local topics_strs = {}
    for _, v in ipairs(topics) do
        local s
        if v then
            s = '"' .. v .. '"'
        else
            s = "null"
        end
        table.insert(topics_strs, s)
    end
    local topic_str = table.concat(topics_strs, ", ")

    local cmd = string.format(
        cast_logs_template,
        self.endpoint,
        contract_address,
        topic_str
    )

    local handle = io.popen(cmd)
    assert(handle)
    local logs = handle:read "*a"
    handle:close()

    if logs:find "Error" then
        error(string.format("Read logs `%s` failed:\n%s", sig, logs))
    end

    local ret = parse_logs(logs, data_sig)
    return ret
end

local cast_call_template = [==[
cast call --rpc-url "%s" "%s" "%s" %s 2>&1
]==]

function Reader:_call(address, sig, args)
    local quoted_args = {}
    for _, v in ipairs(args) do
        table.insert(quoted_args, '"' .. v .. '"')
    end
    local args_str = table.concat(quoted_args, " ")

    local cmd = string.format(
        cast_call_template,
        self.endpoint,
        address,
        sig,
        args_str
    )

    local handle = io.popen(cmd)
    assert(handle)

    local ret = {}
    local str = handle:read()
    while str do
        if str:find "Error" or str:find "error" then
            local err_str = handle:read "*a"
            handle:close()
            error(string.format("Call `%s` failed:\n%s%s", sig, str, err_str))
        end

        table.insert(ret, str)
        str = handle:read()
    end
    handle:close()

    return ret
end

function Reader:read_epochs_sealed(consensus_address)
    local sig = "EpochSealed(uint256,uint256,uint256,bytes32,bytes32,address)"
    local data_sig = "(uint256,uint256,uint256,bytes32,bytes32,address)"

    local logs = self:_read_logs(consensus_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.meta = v.meta

        log.epoch_number = tonumber(v.decoded_data[1])
        log.block_lower_bound = tonumber(v.decoded_data[2])
        log.block_upper_bound = tonumber(v.decoded_data[3])
        log.initial_machine_state_hash = v.decoded_data[4]
        log.tournament = v.decoded_data[6]

        ret[k] = log
    end

    return ret
end

function Reader:read_inputs_added(input_box_address)
    local sig = "InputAdded(address,uint256,bytes)"
    local data_sig = "(bytes)"

    local logs = self:_read_logs(input_box_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.meta = v.meta

        log.app_contract = v.emited_topics[2]
        log.index = tonumber(v.emited_topics[3])
        log.data = v.decoded_data[1]

        ret[k] = log
    end

    return ret
end

return Reader
