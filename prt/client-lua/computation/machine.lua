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

function ComputationState:new(root_hash, halted, yielded, uhalted)
    local r = {
        root_hash = root_hash,
        halted = halted,
        yielded = yielded,
        uhalted = uhalted
    }
    setmetatable(r, self)
    return r
end

function ComputationState.from_current_machine_state(machine)
    local hash = Hash:from_digest(machine.machine:get_root_hash())
    return ComputationState:new(
        hash,
        machine:is_halted(),
        machine:is_yielded(),
        machine:is_uarch_halted()
    )
end

ComputationState.__tostring = function(x)
    return string.format(
        "{root_hash = %s, halted = %s, yielded = %s, uhalted = %s}",
        x.root_hash,
        x.halted,
        x.yielded,
        x.uhalted
    )
end


--
---
--

local Machine = {}
Machine.__index = Machine

local machine_settings = { htif = { no_console_putchar = true } }

function Machine:new_from_path(path)
    local machine = cartesi.machine(path, machine_settings)
    local start_cycle = machine:read_reg("mcycle")

    -- Machine can never be advanced on the micro arch.
    -- Validators must verify this first
    assert(machine:read_reg("uarch_cycle") == 0)

    -- Derive snapshot_dir from path's parent directory
    local snapshot_dir = path:match("(.*)/[^/]*$") or "/dispute/snapshots"

    local b = {
        machine = machine,
        input_count = 0,
        cycle = 0,
        ucycle = 0,
        start_cycle = start_cycle,
        initial_hash = Hash:from_digest(machine:get_root_hash()),
        snapshot_path = path,
        snapshot_dir = snapshot_dir
    }

    setmetatable(b, self)
    return b
end

local function find_closest_snapshot(path, current_cycle, cycle)
    local directories = {}

    -- Collect all directories and their corresponding numbers
    -- Check if the directory exists and is not empty
    local handle = io.popen('ls -d ' .. path .. '/*/ 2>/dev/null')
    if handle then
        for dir in handle:lines() do
            local dir_name = dir:gsub("/$", "")            -- Get the directory name
            local number = tonumber(dir_name:match("%d+")) -- Extract the number from the name

            if number then
                table.insert(directories, { path = dir_name, number = number })
            end
        end
        handle:close() -- Close the handle
    end

    -- Sort directories by the extracted number
    table.sort(directories, function(a, b) return a.number < b.number end)

    -- Binary search for the closest number smaller than target cycle
    local closest_dir = nil
    local closest_cycle = nil
    local low, high = 1, #directories

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local mid_number = directories[mid].number

        if mid_number < cycle and mid_number > current_cycle then
            closest_dir = directories[mid].path
            closest_cycle = directories[mid].number
            low = mid + 1  -- Search in the larger half
        else
            high = mid - 1 -- Search in the smaller half
        end
    end

    return closest_cycle, closest_dir
end

function Machine:take_snapshot(snapshot_dir, cycle, handle_rollups)
    local input_mask = consts.barch_span_to_input
    if handle_rollups and ((cycle & input_mask) == 0) then
        if (not self.yielded) then
            -- don't snapshot a machine state that's freshly fed with input without advance
            return
        end
    end

    if not helper.exists(snapshot_dir) then
        helper.mkdir_p(snapshot_dir)
    end

    local snapshot_path = snapshot_dir .. "/" .. tostring(cycle)

    if not helper.exists(snapshot_path) then
        -- print("saving snapshot", snapshot_path)
        self.machine:store(snapshot_path)
    end
end

function Machine:load_snapshot(snapshot_dir, cycle)
    local snapshot_cycle = cycle
    local snapshot_path = snapshot_dir .. "/" .. tostring(cycle)

    if not helper.exists(snapshot_path) then
        -- find closest snapshot if direct snapshot doesn't exists
        snapshot_cycle, snapshot_path = find_closest_snapshot(snapshot_dir, self.cycle, cycle)
    end
    if snapshot_path then
        print(string.format("load snapshot from %s", snapshot_path))
        local machine = cartesi.machine(snapshot_path, machine_settings)
        self.cycle = snapshot_cycle
        self.machine = machine
    end
end

local function add_and_clamp(x, y)
    if math.ult(x, arithmetic.max_uint64 - y) then
        return x + y
    else
        return arithmetic.max_uint64
    end
end

local function advance_rollup(self, meta_cycle, inputs)
    assert(self:is_yielded())
    local input_count = (meta_cycle >> consts.log2_uarch_span_to_input):touinteger()
    local cycle_mask = (uint256.one() << consts.log2_barch_span_to_input) - 1
    local cycle = ((meta_cycle >> consts.log2_uarch_span_to_barch) & cycle_mask):touinteger()
    local ucycle_mask = (uint256.one() << consts.log2_uarch_span_to_barch) - 1
    local ucycle = (meta_cycle & ucycle_mask):touinteger()
    assert(arithmetic.ulte(input_count, consts.input_span_to_epoch))

    while self.input_count < input_count do
        local input = inputs[self.input_count + 1]

        if not input then
            self.input_count = input_count
            break
        end

        local input_bin = conversion.bin_from_hex_n(input)
        self:feed_input(input_bin)

        repeat
            self:run(arithmetic.max_uint64)
        until self:is_halted() or self:is_yielded()
        assert(not self:is_halted())

        self.input_count = self.input_count + 1
    end
    assert(self.input_count == input_count)

    if cycle == 0 and ucycle == 0 then
        return
    end

    local input = inputs[self.input_count + 1]
    if input then
        local input_bin = conversion.bin_from_hex_n(input)
        self:feed_input(input_bin)
    end

    self:run(cycle)
    self:run_uarch(ucycle)
end

function Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local machine = Machine:new_from_path(path)
    advance_rollup(machine, meta_cycle, inputs)
    return machine
end

local function process_input(machine, log2_stride)
    local stride = 1 << (log2_stride - consts.log2_uarch_span_to_barch)

    local iterations = 0
    local builder = MerkleBuilder:new()
    while true do -- will loop forever if machine never yields
        machine:run(machine.cycle + stride)
        local state = machine:state()
        assert(not state.halted)

        if not state.yielded then
            builder:add(state.root_hash)
            iterations = iterations + 1
        else
            local total = 1 << (consts.log2_barch_span_to_input + consts.log2_uarch_span_to_barch - log2_stride)
            builder:add(state.root_hash, total - iterations)
            return builder:build()
        end
    end
end

function Machine.root_rollup_commitment(pristine_path, log2_stride, inputs)
    local machine = Machine:new_from_path(pristine_path)
    assert(machine:is_yielded())
    assert(consts.log2_barch_span_to_input > (log2_stride - consts.log2_uarch_span_to_barch))

    local max_input_count = 1 << (consts.log2_input_span_to_epoch)

    local builder = MerkleBuilder:new()
    local state = machine:state()
    local initial_hash = state.root_hash

    local input_i = 0
    while input_i < max_input_count do
        if inputs[input_i + 1] then
            local input_bin = conversion.bin_from_hex_n(inputs[input_i + 1])
            machine:feed_input(input_bin);
            local tree = process_input(machine, log2_stride)
            builder:add(tree)
            input_i = input_i + 1
        else
            local tree = process_input(machine, log2_stride)
            builder:add(tree, max_input_count - input_i)
            break
        end
    end

    return initial_hash, builder:build(initial_hash)
end

function Machine:state()
    return ComputationState.from_current_machine_state(self)
end

function Machine:is_halted()
    return self.machine:read_reg("iflags_H") ~= 0
end

function Machine:is_yielded()
    return self.machine:read_reg("iflags_Y") ~= 0
end

function Machine:is_uarch_halted()
    return self.machine:read_reg("uarch_halt_flag") ~= 0
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
    -- before feeding input, the machine state is always valid and yielded, so we can store the snapshot
    -- however if could have been reverted, so we need to check if the snapshot exists
    local root_hash = self.machine:get_root_hash()
    local new_snapshot_path = self.snapshot_dir .. "/" .. root_hash:hex_string()
    if not helper.exists(new_snapshot_path) then
        self.machine:store(new_snapshot_path)
        if self.snapshot_path and helper.exists(self.snapshot_path) then
            helper.remove_file(self.snapshot_path)
        end
    end

    self.snapshot_path = new_snapshot_path
    self:write_checkpoint(root_hash)
    self.machine:send_cmio_response(cartesi.CMIO_YIELD_REASON_ADVANCE_STATE, input_bin);
end

function Machine:run(cycle)
    assert(arithmetic.ulte(self.cycle, cycle))

    local machine = self.machine
    local target_physical_cycle = add_and_clamp(self:physical_cycle(), cycle - self.cycle)

    repeat
        machine:run(target_physical_cycle)
    until self:is_halted() or self:is_yielded() or
        self:physical_cycle() == target_physical_cycle

    if self:is_yielded() then
        -- if it is not reverted, we store the new snapshot and remove the old one
        self:revert_if_needed()
    end

    self.cycle = cycle

    return self:state()
end

function Machine:revert_if_needed()
    -- revert if needed only when machine yields
    assert(self:is_yielded())

    -- we check if the request is accepted
    -- if it is not, we revert the machine state to previous snapshot
    local _, reason, _ = self.machine:receive_cmio_request()
    if reason ~= cartesi.CMIO_YIELD_MANUAL_REASON_RX_ACCEPTED then
        -- Revert to previous snapshot
        local machine = cartesi.machine(self.snapshot_path, machine_settings)
        self.machine = machine
    end
end

function Machine:prove_revert_if_needed()
    local iflags_y_address = self.machine:get_reg_address("iflags_Y")
    local iflags_y_proof = self:prove_read_leaf(iflags_y_address, 3)

    local proof = iflags_y_proof

    local iflags_y = self:is_yielded()
    if iflags_y then
        local to_host_address = self.machine:get_reg_address("htif_tohost")
        local to_host_proof = self:prove_read_leaf(to_host_address, 3)
        proof = proof .. to_host_proof

        local _, reason, _ = self.machine:receive_cmio_request()
        if reason ~= cartesi.CMIO_YIELD_MANUAL_REASON_RX_ACCEPTED then
            local checkpoint_proof = self:prove_read_leaf(consts.CHECKPOINT_ADDRESS, 5)
            proof = proof .. checkpoint_proof
        end
    end

    return proof
end

function Machine:prove_read_leaf(address, log2_size)
    -- always read aligned 32 bytes (one leaf)
    local aligned_address = address & ~0x1F
    local read = self.machine:read_memory(aligned_address, 32)
    local read_hash = Hash:from_digest(read)
    local merkle_proof = self.machine:proof(aligned_address, 5)

    local proof = {}

    if log2_size == 3 then
        -- Append the read data
        for _, byte in ipairs(read) do
            table.insert(proof, byte)
        end
    elseif log2_size == 5 then
        -- Append both read data and read hash
        for _, byte in ipairs(read) do
            table.insert(proof, byte)
        end
        for _, byte in ipairs(read_hash:digest()) do
            table.insert(proof, byte)
        end
    else
        error("log2_size is not 3 or 5")
    end

    -- Append sibling hashes from the merkle proof
    for _, hash in ipairs(merkle_proof.sibling_hashes) do
        if hash then
            for _, byte in ipairs(hash) do
                table.insert(proof, byte)
            end
        end
    end

    local data = table.concat(proof)
    return data
end

function Machine:prove_write_leaf(address)
    -- always write aligned 32 bytes (one leaf)
    local aligned_address = address & ~0x1F
    -- Get proof of write address
    local merkle_proof = self.machine:proof(aligned_address, 5)

    local proof = {}
    for _, hash in ipairs(merkle_proof.sibling_hashes) do
        if hash then
            for _, byte in ipairs(hash) do
                table.insert(proof, byte)
            end
        end
    end

    local data = table.concat(proof)
    return data
end

function Machine:write_checkpoint(root_hash)
    -- Write the current machine state hash to the checkpoint address
    self.machine:write_memory(consts.CHECKPOINT_ADDRESS, root_hash)
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
                table.insert(encoded, a.read)
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


local function get_logs_compute(path, agree_hash, meta_cycle, snapshot_dir)
    local big_step_mask = consts.uarch_span_to_barch

    local base_cycle = (meta_cycle >> consts.log2_uarch_span_to_barch):tointeger()
    local ucycle = (meta_cycle & big_step_mask):tointeger()

    local machine = Machine:new_from_path(path)
    machine:load_snapshot(snapshot_dir, base_cycle)
    machine:run(base_cycle)
    machine:run_uarch(ucycle)
    assert(machine:state().root_hash == agree_hash)

    local logs = {}
    if ((meta_cycle + 1) & big_step_mask):iszero() then
        table.insert(logs, machine.machine:log_step_uarch())
        table.insert(logs, machine.machine:log_reset_uarch())
    else
        table.insert(logs, machine.machine:log_step_uarch())
    end


    return encode_access_logs(logs), machine:state().root_hash
end

local function encode_da(input_bin)
    local input_size_be = string.pack(">I8", input_bin:len())
    local da_proof = input_size_be .. input_bin
    return da_proof
end

local function get_logs_rollups(path, agree_hash, meta_cycle, inputs)
    local input_mask = (uint256.one() << consts.log2_uarch_span_to_input) - 1
    local big_step_mask = arithmetic.max_uint(consts.log2_uarch_span_to_barch)

    assert(((meta_cycle >> consts.log2_uarch_span_to_input) & (~input_mask)):iszero())
    local input_count = (meta_cycle >> consts.log2_uarch_span_to_input):tointeger()

    local logs = {}

    local machine = Machine:new_rollup_advanced_until(path, meta_cycle, inputs)
    local root_hash = machine:state().root_hash
    assert(root_hash == agree_hash)

    if (meta_cycle & input_mask):iszero() then
        local input = inputs[input_count + 1]
        local da_proof
        if input then
            local input_bin = conversion.bin_from_hex_n(input)
            machine:write_checkpoint(root_hash)
            local write_checkpoint_proof = machine:prove_write_leaf(consts.CHECKPOINT_ADDRESS)
            local cmio_log = machine.machine:log_send_cmio_response(
                cartesi.CMIO_YIELD_REASON_ADVANCE_STATE,
                input_bin
            )

            table.insert(logs, cmio_log)
            da_proof = encode_da(input_bin)
            da_proof = da_proof .. write_checkpoint_proof
        else
            da_proof = encode_da("")
        end

        local uarch_step_log = machine.machine:log_step_uarch()
        table.insert(logs, uarch_step_log)

        local step_proof = encode_access_logs(logs)
        local proof = da_proof .. step_proof
        return proof, machine:state().root_hash
    else
        if ((meta_cycle + 1) & big_step_mask):iszero() then
            assert(machine:is_uarch_halted())

            local uarch_step_log = machine.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            local ureset_log = machine.machine:log_reset_uarch()
            table.insert(logs, ureset_log)

            local step_reset_proof = encode_access_logs(logs)
            local revert_proof = machine:prove_revert_if_needed()

            local combined_proof = step_reset_proof .. revert_proof
            return combined_proof, machine:state().root_hash
        else
            local uarch_step_log = machine.machine:log_step_uarch()
            table.insert(logs, uarch_step_log)
            return encode_access_logs(logs), machine:state().root_hash
        end
    end
end

function Machine.get_logs(path, agree_hash, meta_cycle, inputs, snapshot_dir)
    local proofs, next_hash
    if inputs then
        proofs, next_hash = get_logs_rollups(path, agree_hash, meta_cycle, inputs)
    else
        proofs, next_hash = get_logs_compute(path, agree_hash, meta_cycle, snapshot_dir)
    end

    print("access logs size: ", proofs:len())
    return string.format('"%s"', conversion.hex_from_bin_n(proofs)), next_hash
end

return Machine
