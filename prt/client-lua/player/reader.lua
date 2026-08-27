local Hash = require "cryptography.hash"
local eth_abi = require "utils.eth_abi"
local bint = require "utils.bint" (256)

local MAX_U64 = (bint.one() << 64) - 1
local MAX_U64_DECIMAL = "18446744073709551615"

local function decoded_uint64(value, name)
    assert(type(value) == "string" and value:match("^%d+$"),
        name .. " is not an unsigned integer")
    local normalized = value:gsub("^0+", "")
    assert(#normalized < #MAX_U64_DECIMAL
        or #normalized == #MAX_U64_DECIMAL
        and normalized <= MAX_U64_DECIMAL,
        name .. " exceeds uint64")
    local parsed = bint(value)
    assert(bint.ule(parsed, MAX_U64), name .. " exceeds uint64")
    return parsed
end

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

    if not data or data == "0x" then
        return {}
    end

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

local function sanitize_string(s)
    -- remove spaces, scientific notations and color code
    return s:gsub("%s+", ""):gsub("%b[]", ""):gsub("\27%[[%d;]*m", "")
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

function Reader:_read_logs(tournament_address, sig, topics, data_sig)
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
        tournament_address,
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

function Reader:read_match_created(tournament_address)
    local sig = "MatchCreated(bytes32,bytes32,bytes32,bytes32,uint64)"
    local data_sig = "(bytes32,uint64)"

    local logs = self:_read_logs(tournament_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.tournament_address = tournament_address
        log.meta = v.meta

        log.match_id_hash = Hash:from_digest_hex(v.emited_topics[2])
        log.commitment_one = Hash:from_digest_hex(v.emited_topics[3])
        log.commitment_two = Hash:from_digest_hex(v.emited_topics[4])
        log.left_hash = Hash:from_digest_hex(v.decoded_data[1])
        log.eliminable_at = decoded_uint64(
            v.decoded_data[2],
            "MatchCreated.eliminableAt"
        )

        ret[k] = log
    end

    return ret
end

function Reader:read_leaf_match_sealed(tournament_address, match_id_hash)
    local sig = "LeafMatchSealed(bytes32,uint64)"
    local data_sig = "(uint64)"
    local match_topic = match_id_hash and
        match_id_hash:hex_string() or false
    local logs = self:_read_logs(
        tournament_address,
        sig,
        { match_topic, false, false },
        data_sig
    )

    local ret = {}
    for index, value in ipairs(logs) do
        ret[index] = {
            tournament_address = tournament_address,
            meta = value.meta,
            match_id_hash =
                Hash:from_digest_hex(value.emited_topics[2]),
            eliminable_at = decoded_uint64(
                value.decoded_data[1],
                "LeafMatchSealed.eliminableAt"
            ),
        }
    end
    return ret
end

function Reader:read_commitment_joined(tournament_address)
    local sig = "CommitmentJoined(bytes32,bytes32,address)"
    local data_sig = "(bytes32)"

    local logs = self:_read_logs(tournament_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.tournament_address = tournament_address
        log.meta = v.meta
        log.root = Hash:from_digest_hex(v.emited_topics[2])

        ret[k] = log
    end

    return ret
end

function Reader:read_tournament_created(tournament_address, match_id_hash)
    local sig = "NewInnerTournament(bytes32,address)"
    local data_sig = "()"

    local logs = self:_read_logs(tournament_address, sig, { match_id_hash:hex_string(), false, false }, data_sig)
    assert(#logs <= 1)

    if #logs == 0 then return false end
    local log = logs[1]

    local child_addr = "0x" .. string.sub(log.emited_topics[3], 27)

    local ret = {
        parent_match = match_id_hash,
        new_tournament = child_addr,
    }

    return ret
end

function Reader:read_constants(tournament_address)
    local sig = "tournamentDescriptor()"
        .. "((bytes32,uint256,uint64,uint64,uint64,uint8))"

    local ret = self:_call(tournament_address, sig, {})
    assert(#ret == 1)

    local compact = sanitize_string(ret[1])
    local log2_stride, height, level, kind = compact:match(
        "^%(0x%x+,%d+,(%d+),(%d+),(%d+),(%d+)%)$"
    )
    assert(kind, "could not decode tournamentDescriptor")
    kind = tonumber(kind)
    assert(kind == 0 or kind == 1,
        "tournamentDescriptor returned an unknown tournament kind")

    local constants = {
        level = tonumber(level),
        kind = kind,
        log2_stride = tonumber(log2_stride),
        height = tonumber(height),
    }

    return constants
end

-- The ABI-encoded TournamentArguments ride the ERC-1167 clone as immutable
-- arguments after the 45-byte proxy runtime; `decode_sig` names the shape.
function Reader:read_clone_args(address, decode_sig)
    local code_cmd = string.format(
        'cast code --rpc-url "%s" "%s" 2>&1', self.endpoint, address
    )
    local handle = io.popen(code_cmd)
    assert(handle)
    local code = handle:read "*a"
    handle:close()
    if code:find "Error" or code:find "error" then
        error(string.format("Code read for `%s` failed:\n%s", address, code))
    end
    code = assert(code:match("(0x%x+)"), "clone has no code")
    assert(#code > 2 + 45 * 2, "clone code carries no immutable arguments")
    local args = "0x" .. code:sub(3 + 45 * 2)

    local decode_cmd = string.format(
        'cast abi-decode "%s" "%s" 2>&1', decode_sig, args
    )
    handle = io.popen(decode_cmd)
    assert(handle)

    local ret = {}
    local str = handle:read()
    while str do
        if str:find "Error" or str:find "error" then
            local err_str = handle:read "*a"
            handle:close()
            error(string.format(
                "Clone args decode `%s` failed:\n%s%s", decode_sig, str, err_str
            ))
        end
        table.insert(ret, str)
        str = handle:read()
    end
    handle:close()

    return ret
end

function Reader:root_tournament_winner(address)
    local sig =
        "tournamentStanding()((uint8,bool,bool,bytes32,bytes32,bytes32,uint64))"
    local ret = self:_call(address, sig, {})
    assert(#ret == 1)

    local compact = sanitize_string(ret[1])
    local standing, candidate, final_state = compact:match(
        "^%((%d+),%a+,%a+,(0x%x+),(0x%x+),0x%x+,%d+%)$"
    )
    assert(standing, "could not decode tournamentStanding")
    standing = tonumber(standing)
    -- A finished root without a winner is a scenario failure, not a result.
    assert(standing ~= 3, "root tournament failed with no winner")

    local winner = {
        has_winner = standing == 2,
        commitment = Hash:from_digest_hex(candidate),
        final = Hash:from_digest_hex(final_state),
    }

    return winner
end

return Reader
