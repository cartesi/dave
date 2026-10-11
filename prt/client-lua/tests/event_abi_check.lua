-- Checks the semantic reader's event layouts against the compiled
-- ITournament ABI, the JSON `forge inspect ITournament abi --json` prints,
-- read from stdin. A stale layout fails nothing else: the reader's log
-- filter just stops matching the event. It also requires every other ABI
-- event to be listed below, so a new event is classified before it can be
-- silently filtered out.
local script_directory = assert(arg[0]:match("^(.*)/[^/]+$"))
local client_directory = assert(script_directory:match("^(.*)/tests$"))
package.path = client_directory .. "/?.lua;" .. package.path

local SemanticReader = require "player.semantic_reader"

-- Events the reader filters out on purpose: the refund accounting, and the
-- standing that the tournament views already report.
local IGNORED = {
    BondRecovered = true,
    PartialBondRefund = true,
    StandingChanged = true,
}

-- One row per event: name, canonical signature, indexed parameter names, and
-- data word names, flattening a static tuple as the layouts do. A dynamic
-- data field fails, since the reader decodes data as fixed words.
local ABI_JQ = [[
def canonical:
    if (.type | startswith("tuple"))
    then "(" + ([.components[] | canonical] | join(",")) + ")"
        + (.type | ltrimstr("tuple"))
    else .type end;
def words:
    if .type == "tuple"
    then .name as $tuple | .components[] | words | "\($tuple).\(.)"
    elif (.type | test("^(bytes|string)$|\\["))
    then error("\(.name) is not a static data word")
    else .name end;
.[] | select(.type == "event") | [
    .name,
    "\(.name)(\([.inputs[] | canonical] | join(",")))",
    ([.inputs[] | select(.indexed) | .name] | join(",")),
    ([.inputs[] | select(.indexed | not) | words] | join(","))
] | @tsv
]]

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function compiled_events()
    local abi = io.read("a")
    assert(abi:match("%S"), "no ABI on stdin")
    local path = assert(os.tmpname())
    local file = assert(io.open(path, "wb"))
    assert(file:write(abi))
    assert(file:close())
    local reader = assert(io.popen(
        "jq -r " .. shell_quote(ABI_JQ) .. " " .. shell_quote(path),
        "r"
    ))
    local output = reader:read("a")
    local ok = reader:close()
    os.remove(path)
    assert(ok, "jq could not read the ABI")

    local events = {}
    for line in output:gmatch("[^\n]+") do
        local name, signature, indexed, data =
            line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        assert(name, "unexpected jq row: " .. line)
        events[name] = {
            signature = signature,
            indexed = indexed,
            data = data,
        }
    end
    return events
end

local compiled = compiled_events()
local failures = {}
local function expect(name, what, ours, theirs)
    if ours ~= theirs then
        table.insert(failures, string.format(
            "%s %s:\n  reader: %s\n  ABI:    %s",
            name,
            what,
            ours,
            theirs
        ))
    end
end

local layouts = SemanticReader.EVENT_LAYOUTS
local covered = {}
for _, layout in ipairs(layouts) do
    covered[layout.name] = true
    local event = compiled[layout.name]
    if event == nil then
        table.insert(failures, layout.name .. " is not in the ABI")
    else
        expect(layout.name, "signature", layout.signature, event.signature)
        expect(
            layout.name,
            "indexed topics",
            table.concat(layout.indexed, ","),
            event.indexed
        )
        expect(
            layout.name,
            "data words",
            table.concat(layout.data, ","),
            event.data
        )
    end
end
for name in pairs(compiled) do
    if not covered[name] and not IGNORED[name] then
        table.insert(failures, name
            .. " is in the ABI but neither decoded nor ignored")
    end
end

if #failures > 0 then
    table.sort(failures)
    io.stderr:write(table.concat(failures, "\n"), "\n")
    os.exit(1)
end
io.write(string.format(
    "%d structural event layouts match the ITournament ABI\n",
    #layouts
))
