local MerkleBuilder = require "cryptography.merkle_builder"
local Machine = require "computation.machine"

local conversion = require "utils.conversion"
local cartesi = require "cartesi"
local arithmetic = require "utils.arithmetic"
local consts = require "computation.constants"
local uint256 = require "utils.bint" (256)
local helper = require "utils.helper"

local ulte = arithmetic.ulte

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
    local machine_state
    local builder = MerkleBuilder:new()

    local i = 0
    repeat
        machine_state = machine:increment_uarch()
        builder:add(machine_state.root_hash)
        i = i + 1
    until machine_state.uhalted

    -- Add all remaining fixed-point states, filling the tree up to the last leaf.
    builder:add(machine_state.root_hash, consts.uarch_span_to_barch - i)

    -- At this point, we've added `2^a - 1` hashes to the inner merkle builder.
    -- Note that these states range from "meta" ucycle `1` to `2^a - 1`.

    -- Now we do the last state transition (ureset), and add the last state,
    -- closing in a power-of-two number of leaves (`2^a` leaves).
    machine_state = machine:ureset()

    -- Check if machine is yielded and handle revert if needed
    if machine:is_yielded() then
        machine:revert_if_needed()
    end
    machine_state = machine:state()
    builder:add(machine_state.root_hash)

    return builder:build(), machine_state
end

local function build_small_machine_commitment(log2_stride_count, machine, initial_state)
    local builder = MerkleBuilder:new()
    local instruction_count = arithmetic.max_uint(log2_stride_count - consts.log2_uarch_span_to_barch)
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

local function build_big_machine_commitment(log2_stride, log2_stride_count, machine, initial_state)
    local builder = MerkleBuilder:new()
    local instruction_count = 1 << log2_stride_count

    local big_arch_stride = 1 << (log2_stride - consts.log2_uarch_span_to_barch)

    local iterations = 0
    while math.ult(iterations, instruction_count) do
        print_flush_same_line(string.format(
            "building big machine commitment (%d/%d)...",
            iterations, instruction_count
        ))

        local machine_state = machine:run(machine.cycle + big_arch_stride)

        if not (machine_state.halted or machine_state.yielded) then
            builder:add(machine_state.root_hash)
            iterations = iterations + 1
        else
            -- add this loop plus all remainings
            builder:add(machine_state.root_hash, instruction_count - iterations)
            break
        end
    end
    finish_print_flush_same_line()

    return initial_state, builder:build(initial_state)
end

local function build_commitment(base_cycle, log2_stride, log2_stride_count, machine_path, inputs)
    local machine

    assert(inputs)
    machine = Machine:new_rollup_advanced_until(machine_path, base_cycle, inputs)
    local mask = (uint256.one() << (consts.log2_barch_span_to_input + consts.log2_uarch_span_to_barch)) - 1
    local initial_state = machine:state().root_hash

    if (base_cycle & mask):iszero() then
        assert(machine:state().yielded)
        local input_i = (base_cycle >> consts.log2_uarch_span_to_input):touinteger()
        if inputs[input_i + 1] then
            local input_bin = conversion.bin_from_hex_n(inputs[input_i + 1])
            machine:feed_input(input_bin)
        end
    end

    if log2_stride >= consts.log2_uarch_span_to_barch then
        assert(log2_stride + log2_stride_count <= consts.log2_uarch_span_to_epoch)
        return build_big_machine_commitment(log2_stride, log2_stride_count, machine, initial_state)
    else
        assert(log2_stride == 0)
        return build_small_machine_commitment(log2_stride_count, machine, initial_state)
    end
end

local CommitmentBuilder = {}
CommitmentBuilder.__index = CommitmentBuilder

function CommitmentBuilder:new(machine_path, inputs, root_commitment)
    -- receive honest root commitment from main process
    local commitments = {
        [0] = {
            [tostring(uint256.zero())] = root_commitment
        }
    }

    local c = {
        commitments = commitments,
        machine_path = machine_path,
        inputs = inputs,
    }
    setmetatable(c, self)
    return c
end

function CommitmentBuilder:build(base_cycle, level, log2_stride, log2_stride_count)
    local base_cycle_str = tostring(base_cycle)
    if not self.commitments[level] then
        self.commitments[level] = {}
    elseif self.commitments[level][base_cycle_str] then
        return self.commitments[level][base_cycle_str]
    end

    local _, commitment = build_commitment(base_cycle, log2_stride, log2_stride_count, self.machine_path, self.inputs)
    self.commitments[level][base_cycle_str] = commitment
    return commitment
end

return CommitmentBuilder
