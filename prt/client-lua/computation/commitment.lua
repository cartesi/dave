local MerkleBuilder = require "cryptography.merkle_builder"
local Machine = require "computation.machine"

local arithmetic = require "utils.arithmetic"
local consts = require "computation.constants"

local ulte = arithmetic.ulte

local handle_rollups = false


local function print_flush_same_line(args_str)
    io.write(string.format("\r%s", args_str))
    -- Flush the output to ensure it appears immediately
    io.flush()
end

local function finish_print_flush_same_line()
    io.write("\n")
    -- Flush the output to ensure it appears immediately
    io.flush()
end

local function run_uarch_span(machine)
    assert(machine.ucycle == 0)
    local machine_state = machine:increment_uarch()
    local builder = MerkleBuilder:new()

    local i = 0
    repeat
        builder:add(machine_state.root_hash)
        machine_state = machine:increment_uarch()
        i = i + 1
    until machine_state.uhalted

    -- Add all remaining fixed-point states, filling the tree up to the last leaf.
    builder:add(machine_state.root_hash, consts.uarch_span - i)

    -- At this point, we've added `2^a - 1` hashes to the inner merkle builder.
    -- Note that these states range from "meta" ucycle `1` to `2^a - 1`.

    -- Now we do the last state transition (ureset), and add the last state,
    -- closing in a power-of-two number of leaves (`2^a` leaves).
    machine_state = machine:ureset()
    builder:add(machine_state.root_hash)

    return builder:build(), machine_state
end

local function build_small_machine_commitment(log2_stride_count, machine, initial_state, snapshot_dir)
    local builder = MerkleBuilder:new()
    local instruction_count = arithmetic.max_uint(log2_stride_count - consts.log2_uarch_span)
    local instruction = 0
    while ulte(instruction, instruction_count) do
        print_flush_same_line(string.format(
            "building small machine commitment (%d/%d)...",
            instruction, instruction_count
        ))

        local uarch_span, machine_state = run_uarch_span(machine)
        builder:add(uarch_span)
        instruction = instruction + 1

        -- Optional optimization, just comment to remove.
        if machine_state.halted or machine_state.yielded then
            uarch_span, _ = run_uarch_span(machine)
            builder:add(uarch_span, instruction_count - instruction + 1)
            break
        end
    end
    finish_print_flush_same_line()

    return initial_state, builder:build(initial_state)
end

local function build_big_machine_commitment(base_cycle, log2_stride, log2_stride_count, machine, initial_state)
    local builder = MerkleBuilder:new()
    local instruction_count = arithmetic.max_uint(log2_stride_count)
    local instruction = 0

    while ulte(instruction, instruction_count) do
        print_flush_same_line(string.format(
            "building big machine commitment (%d/%d)...",
            instruction, instruction_count
        ))

        local cycle = ((instruction + 1) << (log2_stride - consts.log2_uarch_span))
        local machine_state = machine:run(base_cycle + cycle)

        if machine_state.halted or machine_state.yielded then
            -- add this loop plus all remainings
            builder:add(machine_state.root_hash, instruction_count - instruction + 1)
            break
        else
            builder:add(machine_state.root_hash)
            instruction = instruction + 1
        end
    end
    finish_print_flush_same_line()

    return initial_state, builder:build(initial_state)
end

local function build_commitment(base_cycle, log2_stride, log2_stride_count, machine_path, snapshot_dir, inputs)
    local machine = Machine:new_from_path(machine_path)
    machine:load_snapshot(snapshot_dir, base_cycle)

    local initial_state
    if inputs then
        -- treat it as rollups
        -- the base_cycle may be the cycle to receive input,
        -- we need to take the initial state before feeding input to the machine
        handle_rollups = true
        initial_state = machine:run_with_inputs(base_cycle, inputs, snapshot_dir).root_hash
    else
        -- treat it as compute
        handle_rollups = false
        initial_state = machine:run(base_cycle).root_hash -- taking snapshot for leafs to save time in next level
        machine:take_snapshot(snapshot_dir, base_cycle, handle_rollups)
    end

    if log2_stride >= consts.log2_uarch_span then
        assert(
            log2_stride + log2_stride_count <=
            consts.log2_input_span + consts.log2_emulator_span + consts.log2_uarch_span
        )
        return build_big_machine_commitment(base_cycle, log2_stride, log2_stride_count, machine, initial_state)
    else
        assert(log2_stride == 0)
        return build_small_machine_commitment(log2_stride_count, machine, initial_state, snapshot_dir)
    end
end

local CommitmentBuilder = {}
CommitmentBuilder.__index = CommitmentBuilder

function CommitmentBuilder:new(machine_path, snapshot_dir, root_commitment)
    -- receive honest root commitment from main process
    local commitments = { [0] = { [0] = root_commitment } }

    local c = {
        commitments = commitments,
        machine_path = machine_path,
        snapshot_dir = snapshot_dir
    }
    setmetatable(c, self)
    return c
end

function CommitmentBuilder:build(base_cycle, level, log2_stride, log2_stride_count, inputs)
    if not self.commitments[level] then
        self.commitments[level] = {}
    elseif self.commitments[level][base_cycle] then
        return self.commitments[level][base_cycle]
    end

    local _, commitment = build_commitment(base_cycle, log2_stride, log2_stride_count, self.machine_path,
        self.snapshot_dir, inputs)
    self.commitments[level][base_cycle] = commitment
    return commitment
end

-- local path = "program/simple-program"
-- -- local initial, tree = build_commitment(0, 0, 64, path)
-- local initial, tree = build_commitment(400, 0, 67, path)
-- local initial, tree = build_commitment(0, 64, 63, path)
-- print(initial, tree.root_hash)

-- 0x95ebed36f6708365e01abbec609b89e5b2909b7a127636886afeeffafaf0c2ec
-- 0x0f42278e1dd53a54a4743633bcbc3db7035fd9952eccf5fcad497b6f73c8917c
--
--0xd4a3511d1c56eb421e64dc218e8d7bf29c5d3ad848306f04c1b7f43b8883b670
--0x66af9174ab9acb9d47d036b2e735cb9ba31226fd9b06198ce5bc0782c5ca03ff
--
-- 0x95ebed36f6708365e01abbec609b89e5b2909b7a127636886afeeffafaf0c2ec
-- 0xa27e413a85c252c5664624e5a53c5415148b443983d7101bb3ca88829d1ab269


--[[
--[[
a = 2
b = 2

states = 2^b + 1

x (0 0 0 | x) (0 0 0 | x) (0 0 0 | x) (0 0 0 | x)
0  1 2 3   0   1 2 3   0   1
--]]




-- local function x(log2_stride, log2_stride_count, machine)
--     local uarch_instruction_count = arithmetic.max_uint(log2_stride_count)
--     local stride = 1 << log2_stride
--     local inner_builder = MerkleBuilder:new()

--     local ucycle = stride
--     while ulte(ucycle, uarch_instruction_count) do
--         machine:run_uarch(ucycle)
--         local state = machine:state()

--         if not state.uhalted then
--             inner_builder:add(state.state)
--             ucycle = ucycle + stride
--         else
--             -- add this loop plus all remainings
--             inner_builder:add(state.state, uarch_instruction_count - ucycle + 1)
--             ucycle = uarch_instruction_count
--             break
--         end
--     end

--     -- At this point, we've added `uarch_instruction_count - 1` hashes to the inner merkle builder.
--     -- Now we do the last state transition (ureset), and add the last state,
--     -- closing in a power-of-two number of leaves (`2^a` leaves).
--     machine:ureset()
--     local state = machine:state()
--     inner_builder:add(state.state)

--     return inner_builder:build()
-- end
--]]

return CommitmentBuilder
