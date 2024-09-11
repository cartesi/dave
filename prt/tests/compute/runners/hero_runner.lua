#!/usr/bin/lua
require "setup_path"

-- Required Modules
local time = require "utils.time"
local helper = require "utils.helper"

-- Main Execution
local player_id = tonumber(arg[1])
local tournament = arg[2]
local machine_path = arg[3]
local extra_data = helper.str_to_bool(arg[4])
local hook

if extra_data then
    hook = require "doom_showcase.hook"
else
    hook = false
end

local Player = require "player.player"
local blockchain_consts = require "blockchain.constants"

local react = Player.new(
    { pk = blockchain_consts.pks[player_id], player_id = player_id },
    tournament,
    machine_path,
    blockchain_consts.endpoint,
    hook
)

repeat
    local status, log = coroutine.resume(react)
    assert(status)

    if log.idle then
        helper.log_timestamp("player idling")
        helper.touch_player_idle(player_id)
    else
        helper.rm_player_idle(player_id)
    end

    time.sleep(5)
until coroutine.status(react) == "dead"
