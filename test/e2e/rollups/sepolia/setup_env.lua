local Reader = require "dave.reader"
local Sender = require "dave.sender"

-- addresses
local APP_ADDRESS = assert(os.getenv("APP_ADDRESS"))
local CONSENSUS_ADDRESS = assert(os.getenv("CONSENSUS_ADDRESS"))
local INPUT_BOX_ADDRESS = assert(os.getenv("INPUT_BOX_ADDRESS"))
local PK_ADDRESS = assert(os.getenv("PK_ADDRESS"))

print(string.format([[
APP_ADDRESS = %s
CONSENSUS_ADDRESS = %s
INPUT_BOX_ADDRESS = %s
PK_ADDRESS = %s
]], APP_ADDRESS, CONSENSUS_ADDRESS, INPUT_BOX_ADDRESS, PK_ADDRESS))

local GATEWAY = assert(os.getenv("GATEWAY"))
local PK = assert(os.getenv("PK"))

local reader = Reader:new(INPUT_BOX_ADDRESS, CONSENSUS_ADDRESS, GATEWAY, 8467207)
local sender = Sender:new(INPUT_BOX_ADDRESS, APP_ADDRESS, PK, GATEWAY)

print(string.format("BALANCE = %s", reader:balance(PK_ADDRESS)))

return {
    app_address = APP_ADDRESS,
    consensus_address = CONSENSUS_ADDRESS,
    input_box_address = INPUT_BOX_ADDRESS,
    signer_address = PK_ADDRESS,
    gateway = GATEWAY,
    pk = PK,
    template_machine = "sepolia/machine-image",

    reader = reader,
    sender = sender,
}
