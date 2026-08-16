local Hash = require "cryptography.hash"
local arithmetic = require "utils.arithmetic"
local cartesi = require "cartesi"
local consts = require "computation.constants"
local conversion = require "utils.conversion"
local helper = require "utils.helper"
local uint256 = require "utils.bint" (256)
local MerkleBuilder = require "cryptography.merkle_builder"

local ComputationState = {}
ComputationState.__index = ComputationState

function ComputationState:new(root_hash, status, uhalted)
    local r = {
        root_hash = root_hash,
        halted = status.halted,
        manual_yielded = status.manual_yielded,
        manual_yield_reason = status.manual_yield_reason,
        awaiting_input = status.awaiting_input,
        rejected = status.rejected,
        uhalted = uhalted,
        exception = status.exception,
        unexpected_manual_yield = status.unexpected_manual_yield,
        mcycle_overflow = status.mcycle_overflow,
        terminal = status.terminal
    }
    setmetatable(r, self)
    return r
end

function ComputationState.from_current_machine_state(machine)
    local hash = Hash:from_digest(machine.machine:get_root_hash())
    return ComputationState:new(hash, machine:status(), machine:is_uarch_halted())
end

ComputationState.__tostring = function(x)
    local format = "{root_hash = %s, halted = %s, manual_yielded = %s, "
        .. "awaiting_input = %s, rejected = %s, uhalted = %s, exception = %s, "
        .. "unexpected_manual_yield = %s, mcycle_overflow = %s}"
    return string.format(
        format,
        x.root_hash,
        x.halted,
        x.manual_yielded,
        x.awaiting_input,
        x.rejected,
        x.uhalted,
        x.exception,
        x.unexpected_manual_yield,
        x.mcycle_overflow
    )
end


--
---
--

local Machine = {}
Machine.__index = Machine

local machine_settings = { htif = { no_console_putchar = true } }

-- Default home for rejection snapshots (the hash-named machine stores
-- feed_input writes): a run-local scratch directory. The old default
-- put them next to the source image, littering shared program
-- directories (test/programs/) and risking collisions between
-- parallel runs; TEST_INSTANCE keeps the scratch disjoint the same
-- way it does the harness's other working-dir singletons. Exported so
-- the harness can clear it at scenario start.
Machine.default_snapshot_scratch = "_machine_scratch"
    .. (os.getenv("TEST_INSTANCE") and ("-" .. os.getenv("TEST_INSTANCE")) or "")

function Machine:new_from_path(path, snapshot_dir)
    local machine = cartesi.machine(path, machine_settings)
    local start_cycle = machine:read_reg("mcycle")

    -- Machine can never be advanced on the micro arch.
    -- Validators must verify this first
    assert(machine:read_reg("uarch_cycle") == 0)

    -- Rejection snapshots go to the run-local scratch unless the caller
    -- provides a dedicated directory (callers own their dir's
    -- lifecycle; the default's parent is ensured here).
    if not snapshot_dir then
        snapshot_dir = Machine.default_snapshot_scratch
        os.execute("mkdir -p " .. snapshot_dir)
    end

    local b = {
        machine = machine,
        input_count = 0,
        cycle = 0,
        ucycle = 0,
        start_cycle = start_cycle,
        initial_hash = Hash:from_digest(machine:get_root_hash()),
        snapshot_path = path,
        initial_snapshot = path,
        snapshot_dir = snapshot_dir
    }

    setmetatable(b, self)
    return b
end

local function add_and_clamp(x, y)
    if math.ult(x, arithmetic.max_uint64 - y) then
        return x + y
    else
        return arithmetic.max_uint64
    end
end

local function advance_rollup(self, meta_cycle, inputs)
    assert(self:is_awaiting_input() or self:is_terminal())
    local input_count = (meta_cycle >> consts.log2_window_span):touinteger()
    local cycle_mask = (uint256.one()
        << cartesi.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE) - 1
    local cycle = ((meta_cycle
        >> cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) & cycle_mask):touinteger()
    local ucycle_mask = (uint256.one()
        << cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) - 1
    local ucycle = (meta_cycle & ucycle_mask):touinteger()
    assert(arithmetic.ulte(input_count, consts.input_index_mask))

    while self.input_count < input_count do
        local input = inputs[self.input_count + 1]

        if not input or self:is_terminal() then
            self.input_count = input_count
            break
        end

        local input_bin = conversion.bin_from_hex_n(input)
        self:feed_input(input_bin)

        repeat
            self.machine:run(arithmetic.max_uint64)
        until self:is_halted() or self:is_manual_yielded() or self:is_mcycle_overflow()

        self:restore_rejected()

        self.input_count = self.input_count + 1
        if self:is_terminal() then
            self.input_count = input_count
            break
        end
    end
    assert(self.input_count == input_count)

    if cycle == 0 and ucycle == 0 then
        return
    end

    local input = inputs[self.input_count + 1]
    if input and not self:is_terminal() then
        local input_bin = conversion.bin_from_hex_n(input)
        self:feed_input(input_bin)
    end

    self:run(cycle)
    self:run_uarch(ucycle)
end

function Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local machine = self:new_from_path(path)
    advance_rollup(machine, meta_cycle, inputs)
    return machine
end

local function process_input(machine, log2_stride)
    local stride = 1
        << (log2_stride - cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
    local total = 1 << (consts.log2_window_span - log2_stride)

    local iterations = 0
    local builder = MerkleBuilder:new()
    while true do
        machine:run(machine.cycle + stride)
        local state = machine:state()

        if not state.awaiting_input and not state.terminal then
            builder:add(state.root_hash)
            iterations = iterations + 1
        else
            builder:add(state.root_hash, total - iterations)
            return builder:build(), state
        end
    end
end

local function fixed_input_commitment(root_hash, log2_stride)
    local total = 1 << (consts.log2_window_span - log2_stride)
    local builder = MerkleBuilder:new()
    builder:add(root_hash, total)
    return builder:build()
end

-- Computes one epoch's commitment from the machine's current state,
-- advancing it through the epoch. A lineage can call this repeatedly,
-- epoch after epoch, without ever touching foreign snapshots.
function Machine:rollup_commitment(log2_stride, inputs)
    assert(self:is_awaiting_input() or self:is_terminal())
    assert(cartesi.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
        > (log2_stride - cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE))

    local max_input_count = 1 << cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH

    local builder = MerkleBuilder:new()
    local initial_hash = self:state().root_hash

    local input_i = 0
    local processing_bigs = {}
    if self:is_terminal() then
        builder:add(fixed_input_commitment(initial_hash, log2_stride), max_input_count)
        return initial_hash, builder:build(initial_hash), processing_bigs
    end

    while input_i < max_input_count do
        if inputs[input_i + 1] then
            local input_bin = conversion.bin_from_hex_n(inputs[input_i + 1])
            self:feed_input(input_bin);
            local tree, state = process_input(self, log2_stride)
            builder:add(tree)
            input_i = input_i + 1
            -- Big cycles input_i consumed; scenarios use it to aim
            -- patch chains at the revert closing slot.
            processing_bigs[input_i] = self._last_input_bigs
            if state.terminal then
                if input_i < max_input_count then
                    builder:add(
                        fixed_input_commitment(state.root_hash, log2_stride),
                        max_input_count - input_i
                    )
                end
                break
            end
        else
            local tree = process_input(self, log2_stride)
            builder:add(tree, max_input_count - input_i)
            break
        end
    end

    return initial_hash, builder:build(initial_hash), processing_bigs
end

function Machine.root_rollup_commitment(pristine_path, log2_stride, inputs)
    local machine = Machine:new_from_path(pristine_path)
    return machine:rollup_commitment(log2_stride, inputs)
end

-- Store the current machine as a new snapshot directory.
function Machine:store_to(path)
    self.machine:store(path)
end

function Machine:state()
    return ComputationState.from_current_machine_state(self)
end

function Machine:is_halted()
    return self.machine:read_reg("iflags_H") ~= 0
end

function Machine:is_manual_yielded()
    return self.machine:read_reg("iflags_Y") ~= 0
end

function Machine:is_uarch_halted()
    return self.machine:read_reg("uarch_halt") ~= 0
end

function Machine:manual_yield_reason()
    if not self:is_manual_yielded() then
        return nil
    end
    local _, reason, _ = self.machine:receive_cmio_request()
    return reason
end

function Machine:is_awaiting_input()
    return self:manual_yield_reason() == cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED
end

function Machine:is_mcycle_overflow()
    return arithmetic.ulte(self.machine:read_reg("imcyclemax"), self:physical_cycle())
end

function Machine:status()
    local reason = self:manual_yield_reason()
    local awaiting_input = reason == cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED
    local rejected = reason == cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED
    local exception = reason == cartesi.HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION
    local unexpected_manual_yield = reason ~= nil and not awaiting_input and not rejected and not exception
    local halted = self:is_halted()
    local mcycle_overflow = self:is_mcycle_overflow()
    return {
        halted = halted,
        manual_yielded = reason ~= nil,
        manual_yield_reason = reason,
        awaiting_input = awaiting_input,
        rejected = rejected,
        exception = exception,
        unexpected_manual_yield = unexpected_manual_yield,
        mcycle_overflow = mcycle_overflow,
        terminal = halted or mcycle_overflow or exception or unexpected_manual_yield,
    }
end

function Machine:is_terminal()
    return self:status().terminal
end

function Machine:physical_cycle()
    return self.machine:read_reg("mcycle")
end

function Machine:physical_uarch_cycle()
    return self.machine:read_reg("uarch_cycle")
end

function Machine:run_uarch(ucycle)
    assert(arithmetic.ulte(self.ucycle, ucycle), string.format("%u, %u", self.ucycle, ucycle))
    self.machine:run_uarch(ucycle)
    self.ucycle = ucycle
end

function Machine:feed_input(input_bin)
    assert(self:is_awaiting_input(), "feed requires a machine awaiting RX_ACCEPTED")

    -- Before feeding input, the machine is awaiting input at a valid state, so
    -- retain that state in case the advance is later rejected.
    local root_hash_string = Hash:from_digest(self.machine:get_root_hash()):hex_string()
    local new_snapshot_path = self.snapshot_dir .. "/" .. root_hash_string
    if not helper.exists(new_snapshot_path) then
        self.machine:store(new_snapshot_path)
        if self.snapshot_path and helper.exists(self.snapshot_path) then
            -- never delete a snapshot we didn't ourselves create
            if self.initial_snapshot ~= self.snapshot_path then
                helper.remove_file(self.snapshot_path)
            end
        end
    end

    self.snapshot_path = new_snapshot_path
    -- Marks the window start so the yield below can report how many
    -- big cycles the input consumed.
    self._input_start_cycle = self:physical_cycle()
    local revert_root_hash = self.machine:get_root_hash()
    self.machine:send_cmio_response(
        cartesi.HTIF_YIELD_REASON_ADVANCE_STATE,
        input_bin,
        revert_root_hash
    )
end

function Machine:run(cycle)
    assert(arithmetic.ulte(self.cycle, cycle))

    local machine = self.machine
    local target_physical_cycle = add_and_clamp(self:physical_cycle(), cycle - self.cycle)

    repeat
        machine:run(target_physical_cycle)
    until self:is_halted() or self:is_manual_yielded() or self:is_mcycle_overflow() or
        self:physical_cycle() == target_physical_cycle

    if self:is_halted() or self:is_manual_yielded() or self:is_mcycle_overflow() then
        -- Captured before a rejection reloads the snapshot: the big
        -- cycle count the input consumed, yield instruction included.
        -- The restore of a rejected input lands at the closing slot of
        -- big cycle (this count - 1) of its window.
        if self._input_start_cycle then
            self._last_input_bigs = self:physical_cycle() - self._input_start_cycle
        end
    end

    self:restore_rejected()
    self.cycle = cycle

    return self:state()
end

function Machine:restore_rejected()
    -- reset_uarch owns the canonical root substitution on-chain, but the
    -- emulator deliberately leaves its physical machine reset. Reload the
    -- pre-input snapshot so subsequent local execution follows that root.
    if self:manual_yield_reason() ~= cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED then
        return false
    end
    assert(self.snapshot_path, "rejected input has no pre-feed snapshot")
    self.machine = cartesi.machine(self.snapshot_path, machine_settings)
    self.ucycle = 0
    return true
end

function Machine:increment_uarch()
    self.machine:run_uarch(self.ucycle + 1)
    self.ucycle = self.ucycle + 1

    return self:state()
end

function Machine:ureset()
    self.machine:reset_uarch()
    self.cycle = self.cycle + 1
    self.ucycle = 0
    self:restore_rejected()

    return self:state()
end

--[[
local keccak = require "cartesi".keccak

local function ver(t, p, s)
    local stride = p >> 3
    for k, v in ipairs(s) do
        if (stride >> (k - 1)) % 2 == 0 then
            t = keccak(t, v)
        else
            t = keccak(v, t)
        end
    end

    return t
end
]]

local function encode_access_logs(logs)
    local encoded = {}

    for _, log in ipairs(logs) do
        for _, a in ipairs(log.accesses) do
            if a.log2_size == 3 then
                local read = assert(a.read, "word access must carry its read value")
                table.insert(encoded, read)
            elseif a.type == "read" then
                local read = assert(a.read, "region read must carry its raw value")
                assert(#read == 32, "chain region reads are one bytes32 value")
                table.insert(encoded, read)
                table.insert(encoded, a.read_hash)
            else
                table.insert(encoded, a.read_hash)
            end

            for _, h in ipairs(a.sibling_hashes) do
                table.insert(encoded, h)
            end
        end
    end

    local data = table.concat(encoded)
    return data
end

local function encode_da(input_bin)
    local input_size_be = string.pack(">I8", input_bin:len())
    local da_proof = input_size_be .. input_bin
    return da_proof
end

-- Produces the chain witness for one transition from an already-positioned
-- machine. Positioning and proving are separate on the Rust path as well.
function Machine:prove_transition(meta_cycle, inputs)
    local input_mask = (uint256.one() << consts.log2_window_span) - 1
    local big_step_mask = consts.uarch_cycle_mask

    assert(((meta_cycle >> consts.log2_window_span) & (~input_mask)):iszero())
    local input_count = (meta_cycle >> consts.log2_window_span):tointeger()

    local logs = {}

    if (meta_cycle & input_mask):iszero() then
        local input = inputs[input_count + 1]
        local da_proof
        if input then
            local input_bin = conversion.bin_from_hex_n(input)
            local revert_root_hash = self.machine:get_root_hash()
            local cmio_log = self.machine:log_send_cmio_response(
                cartesi.HTIF_YIELD_REASON_ADVANCE_STATE,
                input_bin,
                revert_root_hash
            )

            table.insert(logs, cmio_log)
            da_proof = encode_da(input_bin)
        else
            da_proof = encode_da("")
        end

        local uarch_step_log = self.machine:log_step_uarch()
        table.insert(logs, uarch_step_log)

        local cmio_step_proof = encode_access_logs(logs)
        local proof = da_proof .. cmio_step_proof
        return proof, self:state().root_hash
    else
        if ((meta_cycle + 1) & big_step_mask):iszero() then
            local uarch_step_log = self.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            local ureset_log = self.machine:log_reset_uarch()
            table.insert(logs, ureset_log)

            local step_reset_proof = encode_access_logs(logs)
            self:restore_rejected()
            return step_reset_proof, self:state().root_hash
        else
            local uarch_step_log = self.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            return encode_access_logs(logs), self:state().root_hash
        end
    end
end

local function get_logs_rollups(path, agree_hash, meta_cycle, inputs)
    local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local root_hash = machine:state().root_hash
    assert(root_hash == agree_hash)
    return machine:prove_transition(meta_cycle, inputs)
end

function Machine.get_logs(path, agree_hash, meta_cycle, inputs)
    local proofs, next_hash
    proofs, next_hash = get_logs_rollups(path, agree_hash, meta_cycle, inputs)

    print("access logs size: ", proofs:len())
    return string.format('"%s"', conversion.hex_from_bin_n(proofs)), next_hash
end

return Machine
