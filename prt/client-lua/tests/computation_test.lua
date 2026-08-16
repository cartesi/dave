local cartesi = require "cartesi"
local Constants = require "computation.constants"
local Machine = require "computation.machine"
local Test = require "tests.testlib"
local arithmetic = require "utils.arithmetic"
local uint256 = require "utils.bint" (256)

local root_hash = string.rep("\x5a", cartesi.HASH_SIZE)

local function wrapped_machine(options)
    options = options or {}
    local registers = {
        iflags_H = options.halted and 1 or 0,
        iflags_Y = options.yield_reason and 1 or 0,
        imcyclemax = options.imcyclemax or 100,
        mcycle = options.mcycle or 0,
        uarch_halt = options.uarch_halted and 1 or 0,
    }
    local physical = {
        sent = nil,
        stored = nil,
    }

    function physical.read_reg(_, name)
        assert(name ~= "uarch_halt_flag", "used the removed uarch halt register name")
        local value = registers[name]
        assert(value ~= nil, "unexpected register " .. name)
        return value
    end

    function physical.get_root_hash(_)
        return root_hash
    end

    function physical.receive_cmio_request(_)
        assert(options.yield_reason, "machine has no pending manual yield")
        return cartesi.HTIF_YIELD_CMD_MANUAL, options.yield_reason, ""
    end

    function physical:send_cmio_response(reason, data, revert_root_hash)
        self.sent = {
            reason = reason,
            data = data,
            revert_root_hash = revert_root_hash,
        }
    end

    function physical:store(path)
        self.stored = path
    end

    function physical.run(_)
        return options.break_reason or cartesi.BREAK_REASON_REACHED_TARGET_MCYCLE
    end

    local machine = setmetatable({
        machine = physical,
        cycle = 0,
        ucycle = 0,
        snapshot_dir = "/tmp/dave-computation-unit-missing",
        snapshot_path = options.snapshot_path,
        initial_snapshot = options.snapshot_path,
    }, Machine)
    return machine, physical
end

return {
    Test.case("derived computation geometry follows the emulator", function()
        Test.equal(
            Constants.uarch_cycle_mask,
            arithmetic.max_uint(cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
        )
        Test.equal(
            Constants.input_index_mask,
            arithmetic.max_uint(cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH)
        )
        Test.equal(
            Constants.log2_window_span,
            cartesi.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
                + cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
        )
        Test.equal(
            Constants.log2_ruler_span,
            cartesi.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
                + Constants.log2_window_span
        )
    end),

    Test.case("cycle-overflow closing slot proves step then reset", function()
        local physical <close> = cartesi.machine({ ram = { length = 4096 } }, {})
        physical:write_reg("iflags_Y", 1)
        physical:write_reg("htif_tohost_dev", cartesi.HTIF_DEV_YIELD)
        physical:write_reg("htif_tohost_cmd", cartesi.HTIF_YIELD_CMD_MANUAL)
        physical:write_reg(
            "htif_tohost_reason",
            cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED
        )
        local canonical_post = physical:get_root_hash()

        -- Exact source state from v0.21's uarch-overflow-tail boundary:
        -- maximum counter with the halt flag still clear.
        physical:write_reg("uarch_cycle", cartesi.UARCH_CYCLE_MAX)
        Test.equal(physical:read_reg("uarch_halt"), 0)
        local agree = physical:get_root_hash()

        local step = physical:log_step_uarch()
        Test.equal(#step.accesses, 1)
        Test.equal(physical:get_root_hash(), agree)
        physical:reset_uarch()
        Test.equal(physical:get_root_hash(), canonical_post)

        physical:write_reg("uarch_cycle", cartesi.UARCH_CYCLE_MAX)
        local machine = setmetatable({ machine = physical }, Machine)
        local proof, post = machine:prove_transition(
            uint256.fromuinteger(cartesi.UARCH_CYCLE_MAX),
            {}
        )

        Test.equal(#proof, 7136)
        Test.equal(post.digest, canonical_post)
        Test.equal(physical:read_reg("uarch_cycle"), 0)
        Test.equal(physical:read_reg("uarch_halt"), 0)
    end),

    Test.case("advance-state delivery records the pre-feed root", function()
        local machine, physical = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        }

        machine:feed_input("input")

        Test.truthy(physical.stored)
        Test.equal(physical.sent.reason, cartesi.HTIF_YIELD_REASON_ADVANCE_STATE)
        Test.equal(physical.sent.data, "input")
        Test.equal(physical.sent.revert_root_hash, root_hash)
    end),

    Test.case("terminal state classification follows v0.21 precedence", function()
        local accepted = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        }
        local accepted_state = accepted:state()
        Test.equal(accepted_state.terminal, false)
        Test.equal(accepted_state.manual_yielded, true)
        Test.equal(accepted_state.awaiting_input, true)
        Test.equal(accepted_state.rejected, false)

        local rejected = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED,
        }
        local rejected_state = rejected:state()
        Test.equal(rejected_state.terminal, false)
        Test.equal(rejected_state.manual_yielded, true)
        Test.equal(rejected_state.awaiting_input, false)
        Test.equal(rejected_state.rejected, true)

        local exception, exception_physical = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_TX_EXCEPTION,
        }
        local exception_state = exception:state()
        Test.equal(exception_state.terminal, true)
        Test.equal(exception_state.exception, true)
        Test.equal(exception:restore_rejected(), false)
        Test.equal(exception.machine, exception_physical)

        local unexpected = wrapped_machine { yield_reason = 0x7f }
        local unexpected_state = unexpected:state()
        Test.equal(unexpected_state.terminal, true)
        Test.equal(unexpected_state.unexpected_manual_yield, true)

        local halted = wrapped_machine { halted = true }
        local halted_state = halted:state()
        Test.equal(halted_state.terminal, true)
        Test.equal(halted_state.halted, true)

        local overflow = wrapped_machine { mcycle = 100, imcyclemax = 100 }
        local overflow_state = overflow:state()
        Test.equal(overflow_state.terminal, true)
        Test.equal(overflow_state.mcycle_overflow, true)

        local uarch_halted = wrapped_machine { uarch_halted = true }
        Test.equal(uarch_halted:is_uarch_halted(), true)
    end),

    Test.case("rejection reloads the pre-feed snapshot", function()
        local machine = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED,
            snapshot_path = "snapshot-before-input",
        }
        local replacement = {}
        local loaded_path
        local original_constructor = cartesi.machine
        cartesi.machine = function(path)
            loaded_path = path
            return replacement
        end

        local ok, failure = xpcall(function()
            Test.equal(machine:restore_rejected(), true)
        end, debug.traceback)
        cartesi.machine = original_constructor
        assert(ok, failure)

        Test.equal(loaded_path, "snapshot-before-input")
        Test.equal(machine.machine, replacement)
    end),

    Test.case("reject at mcycle overflow still restores the pre-feed snapshot", function()
        local machine = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED,
            mcycle = 100,
            imcyclemax = 100,
            break_reason = cartesi.BREAK_REASON_MCYCLE_OVERFLOW,
            snapshot_path = "snapshot-before-input",
        }
        local _, replacement = wrapped_machine {
            yield_reason = cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED,
        }
        local loaded_path
        local original_constructor = cartesi.machine
        cartesi.machine = function(path)
            loaded_path = path
            return replacement
        end

        local ok, state = xpcall(function()
            return machine:run(1)
        end, debug.traceback)
        cartesi.machine = original_constructor
        assert(ok, state)

        Test.equal(loaded_path, "snapshot-before-input")
        Test.equal(machine.machine, replacement)
        Test.equal(state.awaiting_input, true)
        Test.equal(state.terminal, false)
    end),

    Test.case("terminal manual reasons are not restored", function()
        local machine, physical = wrapped_machine { yield_reason = 0x7f }

        Test.equal(machine:restore_rejected(), false)
        Test.equal(machine.machine, physical)
        Test.equal(machine:state().terminal, true)
    end),

    Test.case("a terminal epoch is one fixed point", function()
        local machine = wrapped_machine { halted = true }

        local initial_hash, commitment = machine:rollup_commitment(44, { "0x01" })
        local height = Constants.log2_ruler_span - 44

        Test.equal(commitment.root_hash, initial_hash:iterated_merkle(height))
    end),
}
