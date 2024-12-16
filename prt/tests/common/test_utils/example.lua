require "setup_path"
assert(#package.loaded == 1)

-- We're currenly on scope "zero"
local env0, const0 = _ENV, require "blockchain.constants"

-- Scope/sandbox creator
local new_scoped_require = require "test_utils.scoped_require"

--
-- Create scope/sandbox 1
local scoped_require1 = new_scoped_require(_ENV)

-- In scope/sandbox 1, load "utils.test"
local env1, const1 = scoped_require1 "test_utils.test"

-- Check that in scope 1, both _ENV and "test_utils.scoped_require" are different
assert(env0 ~= env1)
assert(const0 ~= const1)


--
-- Create scope/sandbox 2
local scoped_require2 = new_scoped_require(_ENV)

-- In sandbox 2, load "utils.test"
local env2, const2 = scoped_require2 "test_utils.test"

-- Check that in scope 2, both _ENV and "test_utils.scoped_require" are different
assert(env1 ~= env2)
assert(const1 ~= const2)


--
-- Applying it to players
--

-- Shared setup
local blockchain_consts = require "blockchain.constants"
local tournament_address = "..."
local machine_path = "..."
local hook = false

-- Create honest player 0 in its own scope/sandbox
local _debug_p0 -- debug only
local player0
do
    local player_id = 0
    local wallet = { pk = blockchain_consts.pks[player_id], player_id = player_id }

    local scoped_require = new_scoped_require(_ENV) -- create sandbox
    local Player = scoped_require "player.player"
    local react = Player.new(
        tournament_address,
        wallet,
        machine_path,
        blockchain_consts.endpoint,
        hook
    )

    player0 = react
    _debug_p0 = Player
end

-- Create honest player 1 in its own scope/sandbox
local _debug_p1 -- debug only
local player1
do
    local player_id = 1
    local wallet = { pk = blockchain_consts.pks[player_id], player_id = player_id }

    local scoped_require = new_scoped_require(_ENV) -- create sandbox
    local Player = scoped_require "player.player"
    local react = Player.new(
        tournament_address,
        wallet,
        machine_path,
        blockchain_consts.endpoint,
        hook
    )

    player1 = react
    _debug_p1 = Player
end

assert(_debug_p0 ~= _debug_p1)

-- now we have to players: player0 and player1.
-- these are actually coroutines!!
-- let's use them.

local function run_player(player, idx)
    local ok, log = coroutine.resume(player)

    if not ok then
        print(string.format("player %d died", idx))
        return false
    elseif coroutine.status(player0) == "dead" then
        print(string.format("player %d has finished", idx))
        return false
    else
        return true, log
    end
end

local function run(players)
    local finished = false

    repeat
        finished = true
        local idle = true

        for i, player in ipairs(players) do
            if not player then
                goto continue
            end

            local ok, log = run_player(player, i)

            if ok then
                finished = finished and log.finished
                idle = idle and log.idle
            end

            ::continue::
        end

        if idle then
            -- all players are idle
            -- evm advance time
        end

        time.sleep(5) -- I'm thinking, can we remove this and just rely on advances?
    until finished
end

-- run { player0, player1 }
