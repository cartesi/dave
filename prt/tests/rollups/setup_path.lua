-- Resolve repo root from caller (e.g. test_cases/simple.lua) so paths work from any cwd.
local function repo_root_from_caller()
    local info = debug.getinfo(2, "S")
    if not info or not info.source then return nil end
    local source = info.source:gsub("^@", "")
    local dir = source:gsub("/[^/]*$", "")
    if dir == "" or dir == source then return nil end
    return dir .. "/../../../"
end

local repo_root = repo_root_from_caller() or "../../.."
local rollups = repo_root .. "/prt/tests/rollups"

local usr = repo_root .. "/usr"
package.path = usr .. "/share/lua/5.4/?.lua;" .. package.path
package.cpath = usr .. "/lib/lua/5.4/?.so;" .. package.cpath

-- Client-lua and test common (relative to rollups)
package.path = package.path .. ";" .. rollups .. "/../common/?.lua;" .. rollups .. "/../../client-lua/?.lua"
