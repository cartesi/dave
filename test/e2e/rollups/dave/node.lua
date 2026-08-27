-- THE SEAM: this file is the only place in the harness allowed to touch
-- node internals (its SQLite schemas and process lifecycle). Everything
-- it reads serves synchronization or produces cross-check subjects; the
-- oracle in test_env.lua never consumes node state. When the node's
-- schema changes, this file is the complete update surface.

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local helper = require "utils.helper"
local time = require "utils.time"

local ANVIL_ADDRESS_7 = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"
local ANVIL_KEY_7 = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"

-- TEST_INSTANCE isolates parallel runs (see blockchain.constants):
-- every working-directory singleton this file owns gets the suffix,
-- and the node is pointed at the instance's anvil explicitly.
local INSTANCE = os.getenv("TEST_INSTANCE")
local SUFFIX = INSTANCE and ("-" .. INSTANCE) or ""
local DAVE_LOG = "dave" .. SUFFIX .. ".log"
local STATE_DIR = "_state" .. SUFFIX
local ENDPOINT = require("blockchain.constants").endpoint

local function start_dave_node(machine_path, app_address, db_path, sleep_duration, snapshot_gap,
                               verbosity, trace_level)
    -- Appends to the log so respawns keep one monotonic file; Dave:new
    -- archives the previous run's log once per test run. An explicit
    -- snapshot gap of 1 keeps every input boundary so disputes
    -- exercise mid-epoch snapshot resumes; the default is 2, and a
    -- scenario can pass a larger gap to exercise the batched advance
    -- cadence instead (one commit per gap of inputs).
    local cmd = string.format(
        [[echo $$ ; exec env MACHINE_PATH='%s' APP_ADDRESS='%s' STATE_DIR='%s' \
        RUST_BACKTRACE='%s' RUST_LOG='info',cartesi_rollups_prt_node='%s' \
        ../../../target/debug/cartesi-rollups-prt-node --sleep-duration-seconds %s \
        --snapshot-gap-inputs %d --web3-rpc-url %s pk --web3-private-key %s >> %s 2>&1]],
        machine_path, app_address, db_path, trace_level, verbosity, sleep_duration, snapshot_gap,
        ENDPOINT, ANVIL_KEY_7, DAVE_LOG
    )

    local reader = io.popen(cmd)
    assert(reader, "`popen` returned nil reader")

    local pid = tonumber(reader:read())

    local handle = { reader = reader, pid = pid, stopped = false }
    setmetatable(handle, {
        __gc = function(t)
            if not t.stopped then
                helper.stop_pid(t.reader, t.pid)
            end
        end
    })

    print(string.format("Dave node running with pid %d", pid))
    return handle
end

local Dave = {}
Dave.__index = Dave
Dave.wallet_address = ANVIL_ADDRESS_7

function Dave:new(machine_path, app_address, sender, sleep_duration, snapshot_gap, verbosity,
                  trace_level)
    -- Default 2, not 1: at gap 1 every input is a boundary, which
    -- leaves three node paths dark in e2e - the non-boundary GC (its
    -- modulo never fires), multi-input advance batches, and dispute
    -- positioning's replay past a boundary. Gap 2 exercises all
    -- three in every scenario for at most one input of extra replay.
    -- kill_catchup pins gap 1 to keep the degenerate case covered;
    -- production defaults to 64 (storage/open.rs).
    snapshot_gap = snapshot_gap or 2

    -- trace, debug, info, warn, error
    verbosity = verbosity or os.getenv("VERBOSITY") or 'debug'

    -- 0, 1, full
    trace_level = trace_level or os.getenv("TRACE_LEVEL") or 'full'

    local n = {
        initial_machine_path = assert(machine_path),
        sender = sender,
        log_path = DAVE_LOG,
        _spawn_args = { machine_path, app_address, STATE_DIR .. "/", sleep_duration, snapshot_gap,
            verbosity, trace_level },
    }
    os.execute(string.format("rm -rf %s && mkdir %s", STATE_DIR, STATE_DIR))
    -- One generation of forensics: the 2026-07-09 crash decomposition
    -- died because the next run truncated the only evidence.
    os.execute(string.format("rm -f %s.prev; mv %s %s.prev 2>/dev/null; true",
        DAVE_LOG, DAVE_LOG, DAVE_LOG))

    setmetatable(n, self)
    n:respawn()
    return n
end

-- Restart support: kill sends a raw signal (SIGKILL by default - WAL
-- recovery and half-written state are the subject, so no graceful
-- shutdown), respawn relaunches the node over the surviving _state/.

function Dave:kill(signal)
    signal = signal or 9
    local handle = assert(self._handle, "node is not running")
    print(string.format("[Dave] kill -%d %d", signal, handle.pid))
    handle.stopped = true
    os.execute(string.format("kill -%d %d", signal, handle.pid))
    handle.reader:close()
    self._handle = nil
end

function Dave:respawn()
    assert(not self._handle, "node is already running")
    self._handle = start_dave_node(table.unpack(self._spawn_args))
end

-- One non-blocking scan for a line matching `pattern` (a Lua pattern)
-- in the node log past byte `offset` (0 for the start of the run).
-- Returns (matched_offset or nil, next_scan_offset): the first is the
-- position just past the matched line, the second lets callers skip
-- already-scanned lines on the next probe. Kill points are log lines,
-- not sleeps; patterns used by scenarios form a stable-marker contract
-- (see docs/test-harness.md).
function Dave:find_log(pattern, offset)
    offset = offset or 0
    local file = io.open(self.log_path, "r")
    if not file then
        return nil, offset
    end
    file:seek("set", offset)
    local chunk = file:read("*a")
    file:close()
    -- Scan complete lines only; partial tails wait for the next probe.
    local pos = 0
    for line, nl in chunk:gmatch("([^\n]*)(\n)") do
        pos = pos + #line + #nl
        if line:find(pattern) then
            return offset + pos, offset + pos
        end
    end
    return nil, offset + pos
end

-- Blocking form: waits until the pattern appears, returns the offset
-- just past the matched line for chaining triggers.
function Dave:wait_log(pattern, offset)
    local matched
    time.sleep_until(function()
        matched, offset = self:find_log(pattern, offset)
        return matched ~= nil
    end, 1)
    return matched
end

-- The node records an epoch row once its blockchain reader sees the
-- epoch sealed on-chain. Both guarded queries below ask about sealed
-- epochs; the guard distinguishes "not sealed yet" from legitimately
-- empty results (a sealed epoch may have zero inputs).
local SQLITE_DB = "sqlite3 -readonly ./" .. STATE_DIR .. "/db.sqlite3"
local EPOCH_EXISTS_QUERY = SQLITE_DB .. [[ \
'SELECT count(*) FROM epochs WHERE epoch_number = %d' 2>&1
]]
local function epoch_exists(epoch_index)
    local handle = io.popen(string.format(EPOCH_EXISTS_QUERY, epoch_index))
    assert(handle)
    local count = handle:read "*a"
    handle:close()
    if count:find "Error" then
        error(string.format("Read epochs failed:\n%s", count))
    end
    return tonumber(count) == 1
end

-- The node's claim for a rolled epoch: the settlement row's
-- computation hash - the same value it defends in the tournament -
-- plus the epoch's initial machine state. The node persists no
-- unfolded leaf runs anymore; its only level-0 artifact is one
-- window-root row per input. The harness therefore reads the claim
-- itself; the oracle computes its own commitment
-- independently and test_env cross-checks the two. The row appears
-- when the epoch rolls, which is the barrier.
local SETTLEMENT_ROOT_QUERY = SQLITE_DB .. [[ \
'SELECT HEX(computation_hash) FROM settlement_info WHERE epoch_number = %d' 2>&1
]]

function Dave:root_commitment(epoch_index)
    print(string.format("[Dave] root_commitment(epoch_index=%d) called", epoch_index))
    local query = function()
        local machine = Machine:new_from_path(self:machine_path(epoch_index))
        local initial_state = machine:state()

        local handle = io.popen(string.format(SETTLEMENT_ROOT_QUERY, epoch_index))
        assert(handle)
        local root = handle:read "*a"
        handle:close()
        if root:find "Error" then
            error(string.format("Read settlement root failed:\n%s", root))
        end
        root = root:gsub("%s+", "")
        assert(#root == 64, "epoch not rolled yet")

        local claim = Hash:from_digest_hex("0x" .. root)
        print(string.format("[Dave] root_commitment(epoch_index=%d) -> root=%s",
            epoch_index, claim:hex_string()))
        return initial_state, claim
    end

    local initial_state, commitment
    local attempt = 0
    time.sleep_until(function()
        attempt = attempt + 1
        self.sender:advance_blocks(1)
        local ok
        ok, initial_state, commitment = pcall(query)
        if not ok and (attempt == 1 or attempt % 10 == 0) then
            print(string.format("[Dave] root_commitment(epoch_index=%d) attempt %d failed: %s",
                epoch_index, attempt, tostring(initial_state)))
        end
        return ok
    end, 5)

    return initial_state, commitment
end

local MACHINE_PATH_QUERY = SQLITE_DB .. [[ \
'SELECT s.file_path FROM epoch_snapshot_info AS e
JOIN machine_state_snapshots AS s ON s.state_hash = e.state_hash
WHERE e.epoch_number = %d AND e.input_number = 0' 2>&1]]
function Dave:machine_path(epoch_index)
    local query = function()
        assert(epoch_exists(epoch_index), string.format("epoch %d not sealed yet", epoch_index))

        local cmd = string.format(MACHINE_PATH_QUERY, epoch_index)
        local handle = io.popen(cmd)
        assert(handle)
        local path = handle:read()
        local tail = handle:read "*a"
        handle:close()
        if path:find "Error" or tail:find "Error" then
            error(string.format("Read machine path failed:\n%s", path))
        end
        return path
    end

    local path
    time.sleep_until(function()
        self.sender:advance_blocks(1)
        local ok
        ok, path = pcall(query)
        return ok
    end, 5)

    return path
end

local INPUTS_QUERY = SQLITE_DB .. [[ \
'SELECT HEX(input) FROM inputs
  WHERE epoch_number = %d ORDER BY input_index_in_epoch ASC' 2>&1
]]
function Dave:inputs(epoch_index)
    local query = function()
        assert(epoch_exists(epoch_index), string.format("epoch %d not sealed yet", epoch_index))

        local handle = io.popen(string.format(INPUTS_QUERY, epoch_index))
        assert(handle)
        local rows = handle:read "*a"
        handle:close()

        if rows:find "Error" then
            error(string.format("Read inputs failed:\n%s", rows))
        end

        local inputs = {}
        -- Iterate over each line in the input data
        for line in rows:gmatch("[^\n]+") do
            local input = line:match("([^|]+)")
            table.insert(inputs, "0x" .. input)
        end

        return inputs
    end

    local inputs
    time.sleep_until(function()
        self.sender:advance_blocks(1)
        local ok
        ok, inputs = pcall(query)
        return ok
    end, 5)

    return assert(inputs)
end

return Dave
