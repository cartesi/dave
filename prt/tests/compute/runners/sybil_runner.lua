#!/usr/bin/lua
require "setup_path"

-- Required Modules
local time = require "utils.time"
local helper = require "utils.helper"

-- Main Execution
local player_id = tonumber(arg[1])
local tournament = arg[2]
local machine_path = arg[3]
local fake_commitment_count = tonumber(arg[4])

local blockchain_consts = require "blockchain.constants"
local wallet = { pk = blockchain_consts.pks[player_id], player_id = player_id }

local new_sybil = require "runners.helpers.sybil_player"

local react = new_sybil(
    wallet,
    tournament,
    machine_path,
    blockchain_consts.endpoint,
    fake_commitment_count
)

repeat
    local status, log = coroutine.resume(react)
    assert(status)

    if log.finished then return end

    if log.idle then
        helper.log_timestamp("player idling")
        helper.touch_player_idle(player_id)
    else
        helper.rm_player_idle(player_id)
    end

    time.sleep(5)
until coroutine.status(react) == "dead"
