local Adapter = require "player.adapter"
local Fold = require "player.fold"
local Hash = require "cryptography.hash"

-- Reorg-safe semantic observation boundary.
--
-- The reader owns one coherent sample: finalized F, latest H, a proof that F
-- is on H's ancestry, every structural log through H, and all observer calls
-- pinned to H with EIP-1898 requireCanonical. It returns nothing if H changes
-- before the last canonicality check.
local SemanticReader = {}
SemanticReader.__index = SemanticReader

local CastTransport = {}
CastTransport.__index = CastTransport

local function required(value, name)
    assert(value ~= nil, name .. " is required")
    return value
end

local function nonnegative_integer(value, name)
    assert(type(value) == "number"
        and math.type(value) == "integer"
        and value >= 0,
        name .. " must be a nonnegative Lua integer")
    return value
end

local function normalize_hash(value, name)
    name = name or "hash"
    assert(type(value) == "string"
        and #value == 66
        and value:match("^0[xX][%da-fA-F]+$"),
        name .. " must be a 32-byte hex value")
    return value:lower()
end

local function normalize_address(value, name)
    return Adapter.normalize_address(value, name)
end

local function shell_quote(value)
    value = tostring(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_checked(arguments)
    local quoted = {}
    for index, argument in ipairs(arguments) do
        quoted[index] = shell_quote(argument)
    end
    local command = table.concat(quoted, " ") .. " 2>&1"
    local reader = assert(io.popen(command, "r"))
    local output = reader:read("*a")
    local ok, why, code = reader:close()
    assert(ok, string.format(
        "command failed (%s %s): %s",
        tostring(why),
        tostring(code),
        output:gsub("%s+$", "")
    ))
    return output
end

local function jq_checked(raw, program, require_value)
    local flags = require_value and "-er" or "-r"
    local path = assert(os.tmpname())
    local file = assert(io.open(path, "wb"))
    local wrote, write_error = file:write(raw)
    local closed, close_error = file:close()
    if not wrote or not closed then
        os.remove(path)
        error(write_error or close_error, 2)
    end
    local ok, output = pcall(run_checked, {
        "jq",
        flags,
        program,
        path,
    })
    os.remove(path)
    if not ok then
        error(output, 2)
    end
    return output
end

local function split_tabs(line, expected, context)
    line = line:gsub("\n$", "")
    local fields = {}
    local start = 1
    while true do
        local at = line:find("\t", start, true)
        if at == nil then
            table.insert(fields, line:sub(start))
            break
        end
        table.insert(fields, line:sub(start, at - 1))
        start = at + 1
    end
    assert(#fields == expected,
        string.format(
            "%s returned %d fields, expected %d",
            context,
            #fields,
            expected
        ))
    return fields
end

local function parse_quantity(value, name)
    assert(type(value) == "string"
        and value:match("^0[xX][%da-fA-F]+$"),
        name .. " must be an RPC quantity")
    local parsed = tonumber(value:sub(3), 16)
    assert(parsed and math.type(parsed) == "integer" and parsed >= 0,
        name .. " does not fit a nonnegative Lua integer")
    return parsed
end

local function quantity(value)
    return string.format("0x%x", nonnegative_integer(value, "RPC quantity"))
end

local function normalize_head(head, name)
    name = name or "chain head"
    assert(type(head) == "table", name .. " must be a table")
    return {
        number = nonnegative_integer(head.number, name .. " number"),
        hash = normalize_hash(head.hash, name .. " hash"),
        parent_hash = normalize_hash(
            head.parent_hash,
            name .. " parent hash"
        ),
    }
end

local function same_head(left, right)
    return left.number == right.number and left.hash == right.hash
end

local EVENT_SIGNATURES = {
    {
        signature = "CommitmentJoined(bytes32,bytes32,address)",
        kind = Fold.EventKind.COMMITMENT_JOINED,
    },
    {
        signature = "MatchCreated(bytes32,bytes32,bytes32,bytes32)",
        kind = Fold.EventKind.MATCH_CREATED,
    },
    {
        signature = "MatchAdvanced(bytes32,bytes32,bytes32)",
        kind = Fold.EventKind.MATCH_ADVANCED,
    },
    {
        signature = "MatchDeleted(bytes32,bytes32,bytes32,uint8,uint8)",
        kind = Fold.EventKind.MATCH_DELETED,
    },
    {
        signature = "NewInnerTournament(bytes32,address)",
        kind = Fold.EventKind.NEW_INNER_TOURNAMENT,
    },
}

local EVENT_TOPICS = {}
local EVENT_TOPIC_LIST = {}
for _, event in ipairs(EVENT_SIGNATURES) do
    local topic = Hash:from_data(event.signature):hex_string():lower()
    EVENT_TOPICS[topic] = event.kind
    table.insert(EVENT_TOPIC_LIST, topic)
end

function SemanticReader.event_topics()
    local copied = {}
    for index, topic in ipairs(EVENT_TOPIC_LIST) do
        copied[index] = topic
    end
    return copied
end

local function data_words(data, expected, event)
    assert(type(data) == "string" and data:match("^0[xX][%da-fA-F]*$"),
        event .. " has malformed data")
    local body = data:sub(3)
    assert(#body == expected * 64,
        string.format(
            "%s has %d data words, expected %d",
            event,
            #body // 64,
            expected
        ))
    local words = {}
    for index = 1, expected do
        words[index] = body:sub(
            (index - 1) * 64 + 1,
            index * 64
        ):lower()
    end
    return words
end

local function topic_hash(topic, name)
    return Hash:from_digest_hex(normalize_hash(topic, name))
end

local function topic_address(topic, name)
    local normalized = normalize_hash(topic, name)
    assert(normalized:sub(3, 26):match("^0*$"),
        name .. " is not a canonical indexed address")
    return normalize_address("0x" .. normalized:sub(27), name)
end

local function word_tag(word, name)
    assert(word:sub(1, 62):match("^0*$"), name .. " exceeds uint8")
    return tonumber(word:sub(63), 16)
end

local function require_topic_count(log, count, event)
    assert(type(log.topics) == "table" and #log.topics == count,
        string.format(
            "%s has %s topics, expected %d",
            event,
            type(log.topics) == "table" and #log.topics or "malformed",
            count
        ))
end

-- Decode exactly one of the five structural events. The caller intentionally
-- fails on an unknown topic because the RPC request filters this allowlist.
function SemanticReader.decode_event_log(log, topic_map)
    assert(type(log) == "table", "structural log must be a table")
    local tournament = normalize_address(
        log.address,
        "structural log address"
    )
    local block = nonnegative_integer(
        log.block_number,
        "structural log block number"
    )
    assert(type(log.topics) == "table" and log.topics[1],
        "structural log is missing topic zero")
    local topic_zero = normalize_hash(
        log.topics[1],
        "structural event topic zero"
    )
    local kind = (topic_map or EVENT_TOPICS)[topic_zero]
    assert(kind, "unknown structural event topic " .. topic_zero)

    local event
    if kind == Fold.EventKind.COMMITMENT_JOINED then
        require_topic_count(log, 3, "CommitmentJoined")
        local root = topic_hash(log.topics[2], "CommitmentJoined.commitment")
        topic_address(log.topics[3], "CommitmentJoined.submitter")
        local words = data_words(log.data, 1, "CommitmentJoined")
        event = Fold.Event.commitment_joined(
            root,
            Hash:from_digest_hex("0x" .. words[1])
        )
    elseif kind == Fold.EventKind.MATCH_CREATED then
        require_topic_count(log, 4, "MatchCreated")
        local emitted = topic_hash(
            log.topics[2],
            "MatchCreated.matchIdHash"
        )
        local one = topic_hash(log.topics[3], "MatchCreated.one")
        local two = topic_hash(log.topics[4], "MatchCreated.two")
        local words = data_words(log.data, 1, "MatchCreated")
        event = Fold.Event.match_created(
            one,
            two,
            Hash:from_digest_hex("0x" .. words[1]),
            emitted
        )
    elseif kind == Fold.EventKind.MATCH_ADVANCED then
        require_topic_count(log, 2, "MatchAdvanced")
        local words = data_words(log.data, 2, "MatchAdvanced")
        event = Fold.Event.match_advanced(
            topic_hash(log.topics[2], "MatchAdvanced.matchIdHash"),
            Hash:from_digest_hex("0x" .. words[1]),
            Hash:from_digest_hex("0x" .. words[2])
        )
    elseif kind == Fold.EventKind.MATCH_DELETED then
        require_topic_count(log, 4, "MatchDeleted")
        local id_hash = topic_hash(
            log.topics[2],
            "MatchDeleted.matchIdHash"
        )
        local one = topic_hash(log.topics[3], "MatchDeleted.one")
        local two = topic_hash(log.topics[4], "MatchDeleted.two")
        assert(one:join(two) == id_hash,
            "MatchDeleted match id disagrees with ordered commitments")
        local words = data_words(log.data, 2, "MatchDeleted")
        local reason_tag = word_tag(words[1], "MatchDeleted.reason")
        local winner_tag = word_tag(
            words[2],
            "MatchDeleted.winnerCommitment"
        )
        local reasons = {
            [0] = Fold.MatchDeletionReason.STEP,
            [1] = Fold.MatchDeletionReason.TIMEOUT,
            [2] = Fold.MatchDeletionReason.CHILD_TOURNAMENT,
        }
        local winners = {
            [0] = Fold.WinnerCommitment.NEITHER,
            [1] = Fold.WinnerCommitment.ONE,
            [2] = Fold.WinnerCommitment.TWO,
        }
        assert(reasons[reason_tag],
            "unknown match deletion reason " .. tostring(reason_tag))
        assert(winners[winner_tag],
            "unknown winner commitment " .. tostring(winner_tag))
        event = Fold.Event.match_deleted(
            id_hash,
            reasons[reason_tag],
            winners[winner_tag]
        )
    else
        require_topic_count(log, 3, "NewInnerTournament")
        local child = topic_address(
            log.topics[3],
            "NewInnerTournament.childTournament"
        )
        assert(child ~= Adapter.ZERO_ADDRESS,
            "NewInnerTournament child address must be nonzero")
        data_words(log.data, 0, "NewInnerTournament")
        event = Fold.Event.new_inner_tournament(
            topic_hash(
                log.topics[2],
                "NewInnerTournament.matchIdHash"
            ),
            child
        )
    end
    return Fold.event(tournament, block, event)
end

local function normalize_log(log, response_index)
    assert(type(log) == "table",
        "tournament log " .. response_index .. " is malformed")
    assert(log.removed == false,
        "tournament log " .. response_index .. " is marked removed")
    local topics = {}
    assert(type(log.topics) == "table",
        "tournament log " .. response_index .. " has malformed topics")
    for index, topic in ipairs(log.topics) do
        topics[index] = normalize_hash(
            topic,
            string.format("tournament log %d topic %d", response_index, index)
        )
    end
    return {
        address = normalize_address(
            log.address,
            "tournament log " .. response_index .. " address"
        ),
        block_number = nonnegative_integer(
            log.block_number,
            "tournament log " .. response_index .. " block number"
        ),
        block_hash = normalize_hash(
            log.block_hash,
            "tournament log " .. response_index .. " block hash"
        ),
        transaction_hash = normalize_hash(
            log.transaction_hash,
            "tournament log " .. response_index .. " transaction hash"
        ),
        transaction_index = nonnegative_integer(
            log.transaction_index,
            "tournament log " .. response_index .. " transaction index"
        ),
        log_index = nonnegative_integer(
            log.log_index,
            "tournament log " .. response_index .. " log index"
        ),
        removed = false,
        topics = topics,
        data = required(log.data, "tournament log data"),
    }
end

local function normalize_logs(raw_logs)
    local logs = {}
    local block_hashes = {}
    local transaction_hashes = {}
    local transaction_indexes = {}
    for index, raw in ipairs(raw_logs) do
        local log = normalize_log(raw, index)
        logs[index] = log

        local previous_block = block_hashes[log.block_number]
        assert(previous_block == nil or previous_block == log.block_hash,
            string.format(
                "block %d has conflicting hashes across tournament addresses",
                log.block_number
            ))
        block_hashes[log.block_number] = log.block_hash

        local by_index_key =
            tostring(log.block_number) .. ":" .. tostring(log.transaction_index)
        local previous_transaction = transaction_hashes[by_index_key]
        assert(previous_transaction == nil
            or previous_transaction == log.transaction_hash,
            string.format(
                "block %d transaction index %d has conflicting hashes",
                log.block_number,
                log.transaction_index
            ))
        transaction_hashes[by_index_key] = log.transaction_hash

        local by_hash_key =
            tostring(log.block_number) .. ":" .. log.transaction_hash
        local previous_index = transaction_indexes[by_hash_key]
        assert(previous_index == nil
            or previous_index == log.transaction_index,
            string.format(
                "block %d transaction has conflicting indexes",
                log.block_number
            ))
        transaction_indexes[by_hash_key] = log.transaction_index
    end

    table.sort(logs, function(left, right)
        if left.block_number ~= right.block_number then
            return left.block_number < right.block_number
        end
        return left.log_index < right.log_index
    end)
    for index = 2, #logs do
        local previous = logs[index - 1]
        local current = logs[index]
        if previous.block_number == current.block_number then
            assert(previous.log_index < current.log_index,
                string.format(
                    "block %d repeats global log index %d",
                    current.block_number,
                    current.log_index
                ))
            assert(previous.transaction_index <= current.transaction_index,
                string.format(
                    "block %d transaction order contradicts log-index order",
                    current.block_number
                ))
        end
    end
    return logs
end

local function sample_ancestry(transport)
    local finalized = normalize_head(
        transport:get_head("finalized"),
        "sampled finalized head"
    )
    local head = normalize_head(
        transport:get_head("latest"),
        "sampled latest head"
    )
    assert(finalized.number <= head.number,
        string.format(
            "finalized head %d is ahead of latest head %d",
            finalized.number,
            head.number
        ))

    local descending = { head }
    local cursor = head
    while cursor.number > finalized.number do
        local parent = normalize_head(
            transport:get_block_by_hash(cursor.parent_hash),
            "sampled ancestry parent"
        )
        assert(parent.hash == cursor.parent_hash,
            "sampled ancestry parent hash disagrees with child")
        assert(parent.number + 1 == cursor.number,
            "sampled ancestry block numbers are not contiguous")
        table.insert(descending, parent)
        cursor = parent
    end

    local ancestry = {}
    for index = #descending, 1, -1 do
        table.insert(ancestry, descending[index])
    end
    assert(same_head(ancestry[1], finalized),
        "sampled finalized head is not on latest-head ancestry")
    assert(same_head(ancestry[#ancestry], head),
        "sampled ancestry does not end at latest head")
    assert(#ancestry == head.number - finalized.number + 1,
        "sampled ancestry has the wrong length")
    return finalized, head, ancestry
end

local function validate_batch_address(logs, address, context)
    for index, log in ipairs(logs) do
        local normalized_address = normalize_address(
            log.address,
            context .. " log address"
        )
        assert(normalized_address == address,
            string.format(
                "%s log %d belongs to %s, expected %s",
                context,
                index,
                normalized_address,
                address
            ))
    end
end

local function validate_finalized_batch(logs, address, from, finalized)
    validate_batch_address(logs, address, "finalized-range")
    for index, log in ipairs(logs) do
        local block = nonnegative_integer(
            log.block_number,
            "finalized-range log block"
        )
        assert(block >= from and block <= finalized.number,
            string.format(
                "finalized range [%d, %d] returned block %d at index %d",
                from,
                finalized.number,
                block,
                index
            ))
        if block == finalized.number then
            assert(normalize_hash(
                log.block_hash,
                "finalized-boundary log hash"
            ) == finalized.hash,
                "finalized-boundary log belongs to another block hash")
        end
    end
end

local function validate_exact_batch(logs, address, block)
    validate_batch_address(logs, address, "exact-block")
    for index, log in ipairs(logs) do
        assert(nonnegative_integer(
            log.block_number,
            "exact-block log block"
        ) == block.number,
            string.format(
                "exact block %d returned another block at index %d",
                block.number,
                index
            ))
        assert(normalize_hash(
            log.block_hash,
            "exact-block log hash"
        ) == block.hash,
            "unfinalized log belongs to the wrong exact block")
    end
end

local function fetch_address_logs(
    transport,
    address,
    creation_block,
    finalized,
    ancestry,
    topics
)
    local logs = {}
    if creation_block <= finalized.number then
        local finalized_logs = transport:get_logs_range(
            address,
            creation_block,
            finalized.number,
            topics
        )
        assert(type(finalized_logs) == "table",
            "finalized-range log response must be a table")
        validate_finalized_batch(
            finalized_logs,
            address,
            creation_block,
            finalized
        )
        for _, log in ipairs(finalized_logs) do
            table.insert(logs, log)
        end
    end
    for _, block in ipairs(ancestry) do
        if block.number > finalized.number and block.number >= creation_block then
            local tail = transport:get_logs_at_block(address, block, topics)
            assert(type(tail) == "table",
                "exact-block log response must be a table")
            validate_exact_batch(tail, address, block)
            for _, log in ipairs(tail) do
                table.insert(logs, log)
            end
        end
    end
    return logs
end

local function rebuild_fold(root, logs)
    local fold = Fold.new(root)
    for _, log in ipairs(logs) do
        fold:apply(SemanticReader.decode_event_log(log))
    end
    return fold
end

local function discover_fold(
    transport,
    root,
    creation_block,
    finalized,
    ancestry
)
    local streams = {}
    local fetched = {}
    local fold = Fold.new(root)
    while true do
        local pending = {}
        for _, raw_address in ipairs(fold:addresses()) do
            local address = normalize_address(
                raw_address,
                "discovered tournament address"
            )
            if not fetched[address] then
                table.insert(pending, address)
            end
        end
        if #pending == 0 then
            return fold
        end

        for _, address in ipairs(pending) do
            streams[address] = fetch_address_logs(
                transport,
                address,
                creation_block,
                finalized,
                ancestry,
                EVENT_TOPIC_LIST
            )
            fetched[address] = true
        end

        local aggregate = {}
        for _, logs in pairs(streams) do
            for _, log in ipairs(logs) do
                table.insert(aggregate, log)
            end
        end
        fold = rebuild_fold(root, normalize_logs(aggregate))
    end
end

function SemanticReader.new(root, creation_block, transport)
    return setmetatable({
        root = normalize_address(root, "root tournament"),
        creation_block =
            nonnegative_integer(creation_block, "root creation block"),
        transport = required(transport, "semantic reader transport"),
    }, SemanticReader)
end

function SemanticReader.from_endpoint(root, creation_block, endpoint)
    return SemanticReader.new(
        root,
        creation_block,
        CastTransport.new(endpoint)
    )
end

function SemanticReader:fetch()
    local finalized, head, ancestry = sample_ancestry(self.transport)
    local fold = discover_fold(
        self.transport,
        self.root,
        self.creation_block,
        finalized,
        ancestry
    )
    local observations = Adapter.observe_fold(
        self.transport,
        fold,
        head
    )

    local current = normalize_head(
        self.transport:get_block_by_number(head.number),
        "final canonicality check"
    )
    assert(same_head(current, head),
        "sampled latest head is no longer canonical")
    return {
        finalized = finalized,
        head = head,
        fold = fold,
        observations = observations,
    }
end

local BLOCK_JQ = [[
if . == null
    or (.number | type) != "string"
    or (.hash | type) != "string"
    or (.parentHash | type) != "string"
then error("malformed block response")
else [.number, .hash, .parentHash] | @tsv
end
]]

local LOGS_JQ = [[
if type != "array" then error("malformed log response")
else .[] |
    [
        (.address // ""),
        (.blockNumber // ""),
        (.blockHash // ""),
        (.transactionHash // ""),
        (.transactionIndex // ""),
        (.logIndex // ""),
        (if .removed == null then "" else (.removed | tostring) end),
        (if (.topics | type) == "array" then (.topics | join(",")) else "" end),
        (.data // "")
    ] | @tsv
end
]]

function CastTransport.new(endpoint)
    assert(type(endpoint) == "string" and endpoint ~= "",
        "RPC endpoint is required")
    return setmetatable({ endpoint = endpoint }, CastTransport)
end

function CastTransport:_rpc(method, ...)
    local arguments = {
        "cast",
        "rpc",
        "--rpc-url",
        self.endpoint,
        method,
    }
    for _, argument in ipairs { ... } do
        table.insert(arguments, argument)
    end
    return run_checked(arguments)
end

function CastTransport:_block(method, identifier)
    local raw = self:_rpc(method, identifier, "false")
    local fields = split_tabs(
        jq_checked(raw, BLOCK_JQ, true),
        3,
        method
    )
    return {
        number = parse_quantity(fields[1], method .. " block number"),
        hash = normalize_hash(fields[2], method .. " block hash"),
        parent_hash =
            normalize_hash(fields[3], method .. " parent hash"),
    }
end

function CastTransport:get_head(tag)
    assert(tag == "finalized" or tag == "latest",
        "unsupported chain-head tag " .. tostring(tag))
    return self:_block("eth_getBlockByNumber", tag)
end

function CastTransport:get_block_by_hash(hash)
    return self:_block(
        "eth_getBlockByHash",
        normalize_hash(hash, "requested block hash")
    )
end

function CastTransport:get_block_by_number(number)
    return self:_block(
        "eth_getBlockByNumber",
        quantity(number)
    )
end

local function topic_filter(topics)
    assert(type(topics) == "table" and #topics > 0,
        "event topic allowlist is empty")
    local values = {}
    for index, topic in ipairs(topics) do
        values[index] = '"' .. normalize_hash(
            topic,
            "event topic filter"
        ) .. '"'
    end
    return "[[" .. table.concat(values, ",") .. "]]"
end

local function decode_log_rows(raw)
    local output = jq_checked(raw, LOGS_JQ, false)
    local logs = {}
    for line in output:gmatch("[^\n]+") do
        local fields = split_tabs(line, 9, "eth_getLogs")
        local topics = {}
        if fields[8] ~= "" then
            for topic in fields[8]:gmatch("[^,]+") do
                table.insert(topics, topic)
            end
        end
        assert(fields[7] == "true" or fields[7] == "false",
            "eth_getLogs omitted removed metadata")
        table.insert(logs, {
            address = fields[1],
            block_number =
                parse_quantity(fields[2], "log block number"),
            block_hash = fields[3],
            transaction_hash = fields[4],
            transaction_index =
                parse_quantity(fields[5], "log transaction index"),
            log_index = parse_quantity(fields[6], "log index"),
            removed = fields[7] == "true",
            topics = topics,
            data = fields[9],
        })
    end
    return logs
end

function CastTransport:get_logs_range(address, from, to, topics)
    address = normalize_address(address, "log-filter address")
    nonnegative_integer(from, "log-filter start")
    nonnegative_integer(to, "log-filter end")
    assert(from <= to, "log-filter start is after end")
    local filter = string.format(
        [[{"address":"%s","fromBlock":"%s","toBlock":"%s","topics":%s}]],
        address,
        quantity(from),
        quantity(to),
        topic_filter(topics)
    )
    return decode_log_rows(self:_rpc("eth_getLogs", filter))
end

function CastTransport:get_logs_at_block(address, block, topics)
    address = normalize_address(address, "log-filter address")
    block = normalize_head(block, "exact log-filter block")
    local filter = string.format(
        [[{"address":"%s","blockHash":"%s","topics":%s}]],
        address,
        block.hash,
        topic_filter(topics)
    )
    return decode_log_rows(self:_rpc("eth_getLogs", filter))
end

local function calldata_argument(view, argument)
    if view == Adapter.View.TIMEOUT then
        assert(type(argument) == "table",
            "timeout observer call needs a full match id")
        return string.format(
            "(%s,%s)",
            tostring(argument.commitment_one),
            tostring(argument.commitment_two)
        )
    end
    if view == Adapter.View.BISECTING
        or view == Adapter.View.READY
        or view == Adapter.View.SEALED
    then
        return tostring(required(argument, view.name .. " match id hash"))
    end
    assert(argument == nil, view.name .. " does not accept an argument")
    return nil
end

function CastTransport:observer_call(address, view, argument, head)
    address = normalize_address(address, "observer address")
    head = normalize_head(head, "observer canonical head")
    local calldata_arguments = {
        "cast",
        "calldata",
        required(view.signature, "observer signature"),
    }
    local encoded_argument = calldata_argument(view, argument)
    if encoded_argument ~= nil then
        table.insert(calldata_arguments, encoded_argument)
    end
    local calldata = run_checked(calldata_arguments):gsub("%s+$", "")
    assert(calldata:match("^0x[%da-fA-F]+$"),
        "cast calldata returned malformed data")

    local transaction = string.format(
        [[{"to":"%s","data":"%s"}]],
        address,
        calldata
    )
    local block = string.format(
        [[{"blockHash":"%s","requireCanonical":true}]],
        head.hash
    )
    local raw = self:_rpc("eth_call", transaction, block)
    local result = jq_checked(
        raw,
        [[if type == "string" then . else error("malformed eth_call result") end]],
        true
    ):gsub("%s+$", "")
    local decoded = Adapter.decode_result(view, result)
    decoded._trace = {
        address = address,
        argument = encoded_argument,
        head = head.hash,
        calldata = calldata,
    }
    return decoded
end

SemanticReader.CastTransport = CastTransport
SemanticReader.normalize_logs = normalize_logs
SemanticReader.normalize_hash = normalize_hash

return SemanticReader
