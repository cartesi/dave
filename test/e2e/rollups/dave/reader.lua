local eth_abi = require "utils.eth_abi"
local blockchain_constants = require "blockchain.constants"
local Hash = require "cryptography.hash"
local uint256 = require "utils.bint" (256)

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

function Reader:new(input_box_address, dave_app_factory_address, template_hash, sentries, salt, endpoint)
    endpoint = endpoint or blockchain_constants.endpoint
    local reader = {
        input_box_address = input_box_address,
        dave_app_factory_address = dave_app_factory_address,
        endpoint = assert(endpoint),
    }

    setmetatable(reader, self)

    -- pre-calculate app and consensus addresses based on provided template hash and salt values
    reader.app_address, reader.consensus_address = reader:calculate_dave_app_address(template_hash, sentries, salt)

    return reader
end

-- Anvil answers for the whole chain at once, so there is no range paging.
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

    return parse_logs(logs, data_sig)
end

local cast_call_template = [==[
cast call --rpc-url "%s" %s "%s" "%s" %s 2>&1
]==]

-- `block` (optional) pins the call to that block's state.
function Reader:_call(address, sig, args, block)
    local quoted_args = {}
    for _, v in ipairs(args) do
        table.insert(quoted_args, '"' .. v .. '"')
    end
    local args_str = table.concat(quoted_args, " ")

    local cmd = string.format(
        cast_call_template,
        self.endpoint,
        block and string.format("--block %d", block) or "",
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

-- cast annotates large numbers ("123 [1.23e2]"); keep the exact digits.
local function plain_numbers(s)
    return (s:gsub("%s*%[[^%]]*%]", ""))
end

-- The deployment's tournament levels, top first, from the factory the
-- consensus instantiates every epoch's tournament with.
function Reader:read_tournament_levels()
    local factory = self:_call(
        self.consensus_address, "getTournamentFactory()(address)", {}
    )[1]
    local count = assert(tonumber(plain_numbers(
        self:_call(factory, "tournamentLevelCount()(uint64)", {})[1]
    )))

    local levels = {}
    for level = 0, count - 1 do
        local row = plain_numbers(self:_call(
            factory,
            "tournamentParameters(uint64)((uint64,uint64,uint64,uint64,uint64,uint64))",
            { tostring(level) }
        )[1])
        -- (levels, log2step, height, responseBudget, commitmentBudget,
        -- maxAllowance)
        local rows, log2step, height =
            row:match("^%((%d+),%s*(%d+),%s*(%d+),")
        assert(tonumber(rows) == count, "inconsistent tournament level count")
        levels[level + 1] = {
            log2_stride = tonumber(log2step),
            height = tonumber(height),
        }
    end
    return levels
end

-- Each leaf match of `tournament` that sealed: its match ID hash (the
-- indexed LeafMatchSealed topic, which keys its MatchDeleted) and the
-- transition it sealed on. The divergence cycle is read at the
-- LeafMatchSealed block because resolving the match deletes it.
function Reader:read_sealed_leaf_matches(tournament)
    local logs = self:_read_logs(
        tournament, "LeafMatchSealed(bytes32,uint64)", { false, false, false }, "(uint64)"
    )
    local matches = {}
    for _, log in ipairs(logs) do
        local ret = self:_call(
            tournament,
            "sealedMatch(bytes32)(uint8,(bytes32,uint256,uint256,bytes32,bytes32))",
            { log.emited_topics[2] },
            log.meta.block_number
        )
        local view = plain_numbers(assert(ret[2], "sealedMatch returned no view"))
        local cycle = view:match("^%(0x%x+,%s*%d+,%s*(%d+),")
        table.insert(matches, {
            match_id_hash = Hash:from_digest_hex(log.emited_topics[2]),
            cycle = uint256.parse(assert(cycle, "could not decode sealedMatch")),
        })
    end
    return matches
end

function Reader:read_epochs_sealed()
    local sig = "EpochSealed(uint256,uint256,uint256,bytes32,bytes32,address)"
    local data_sig = "(uint256,uint256,bytes32,bytes32,address)"

    local logs = self:_read_logs(self.consensus_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.meta = v.meta

        log.epoch_number = tonumber(v.emited_topics[2])
        log.input_lower_bound = tonumber(v.decoded_data[1])
        log.input_upper_bound = tonumber(v.decoded_data[2])
        log.initial_machine_state_hash = v.decoded_data[3]
        log.tournament = v.decoded_data[5]

        ret[k] = log
    end

    return ret
end

function Reader:read_inputs_added()
    local sig = "InputAdded(address,uint256,bytes)"
    local data_sig = "(bytes)"

    local logs = self:_read_logs(self.input_box_address, sig, { false, false, false }, data_sig)

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

local MATCH_DELETION_REASON = {
    [0] = "step",
    [1] = "timeout",
    [2] = "child_tournament",
}

local WINNER_COMMITMENT = {
    [0] = "none",
    [1] = "one",
    [2] = "two",
}

-- Test-only structural evidence for cleanup scenarios. The production
-- client intentionally hides deleted matches from its live-state view,
-- so retain the deletion reason and participants from the contract log.
function Reader:read_match_deleted(tournament_address, match_id_hash)
    local sig = "MatchDeleted(bytes32,bytes32,bytes32,uint8,uint8)"
    local data_sig = "(uint8,uint8)"
    local match_topic = match_id_hash and match_id_hash:hex_string() or false
    local logs = self:_read_logs(
        tournament_address,
        sig,
        { match_topic, false, false },
        data_sig
    )

    local ret = {}
    for k, v in ipairs(logs) do
        local reason_code = assert(tonumber(v.decoded_data[1]),
            "MatchDeleted reason is not numeric")
        local winner_code = assert(tonumber(v.decoded_data[2]),
            "MatchDeleted winner is not numeric")
        local reason = assert(MATCH_DELETION_REASON[reason_code],
            "MatchDeleted has an unknown reason")
        local winner = assert(WINNER_COMMITMENT[winner_code],
            "MatchDeleted has an unknown winner")

        ret[k] = {
            meta = v.meta,
            match_id_hash = Hash:from_digest_hex(v.emited_topics[2]),
            commitment_one = Hash:from_digest_hex(v.emited_topics[3]),
            commitment_two = Hash:from_digest_hex(v.emited_topics[4]),
            reason = reason,
            winner_commitment = winner,
        }
    end

    return ret
end

function Reader:root_tournament_winner(address)
    local row = assert(self:_call(address,
        "tournamentStanding()((uint8,bool,bool,bytes32,bytes32,bytes32,uint64,uint64))", {})[1],
        "tournamentStanding returned nothing")
    local standing, candidate, final_state = (plain_numbers(row):gsub("%s+", "")):match(
        "^%((%d+),%a+,%a+,(0x%x+),(0x%x+),0x%x+,%d+,%d+%)$"
    )
    assert(standing, "could not decode tournamentStanding")
    standing = tonumber(standing)
    -- A finished root without a winner is a scenario failure, not a result.
    assert(standing ~= 3, "root tournament failed with no winner")

    return {
        has_winner = standing == 2,
        commitment = Hash:from_digest_hex(candidate),
        final = Hash:from_digest_hex(final_state),
    }
end

function Reader:commitment_exists(tournament, commitment)
    local joined = self:_read_logs(
        tournament,
        "CommitmentJoined(bytes32,bytes32,address)",
        { commitment:hex_string(), false, false },
        "(bytes32)"
    )
    return #joined > 0
end

function Reader:calculate_dave_app_address(template_hash, sentries, salt)
    local sig = "calculateDaveAppAddress(bytes32,uint256,address,address[]," ..
        "(address,uint8,uint8,uint64,address),bytes32)(address,address)"
    local claim_staging_period = 1000
    local address_zero = "0x" .. string.rep("00", 20)
    local sentry_manager = address_zero
    local sentries_str = "[" .. table.concat(sentries, ",") .. "]"
    local withdrawal_config = string.format("(%s,0,0,0,%s)", address_zero, address_zero)
    local ret = self:_call(self.dave_app_factory_address, sig,
        { template_hash, claim_staging_period, sentry_manager, sentries_str, withdrawal_config, salt })
    assert(#ret == 2)
    return table.unpack(ret)
end

return Reader
