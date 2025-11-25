require "setup_path"

local env = require "sepolia.setup_env"
local conversion = require "utils.conversion"

local big_input = conversion.bin_from_hex_n("0x6228290203658fd4987e40cbb257cabf258f9c288cdee767eaba6b234a73a2f9")
    :rep((1 << 11) - 10)
assert(big_input:len() == (1 << 16) - 320)

env.sender:tx_add_inputs { { payload = conversion.hex_from_bin_n(big_input) } }
