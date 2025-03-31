require "setup_path"

-- Required Modules
local flat = require "utils.flat"
local json = require "utils.json"
local bint = require 'utils.bint' (256) -- use 256 bits integers
local comp_constants = require "computation.constants"

-- Function to output tournaments
local function output_tournaments(state)
    -- write to a file inside docker
    local state_file = io.open("/app/outputs/current-state.json", "w")
    local root_tournament = state.root_tournament

    if state_file then
        state_file:write(json.encode(flat.flatten(root_tournament)))
        state_file:close()
    end
end

-- Function to output hero claims
local function output_hero_claim(logs)
    if logs ~= nil then
        local hero_state = {}
        local claims_file = io.open("/app/outputs/hero-claims.json", "w")
        hero_state.tournament_address = string.format("%s", logs.tournaments[#logs.tournaments].address)
        hero_state.commitment_root_hash = string.format("%s", logs.commitments[#logs.commitments].root_hash)
        if (logs.latest_match) then
            hero_state.latest_match = string.format("%s", logs.latest_match.match_id_hash)
        end

        if claims_file then
            claims_file:write(json.encode(hero_state))
            claims_file:close()
        end
    end
end

-- Function to copy PNG files
local function copy_png(one, two)
    local directory = "/app/pixels/"
    local pfile = io.popen('ls -a "' .. directory .. '"')
    if pfile then
        for filename in pfile:lines() do
            local png_name = filename:match("[^/]*.png$")
            if png_name ~= nil then
                local left = tonumber(string.match(png_name, "%d+"))
                local right = tonumber(string.match(png_name, "_%d+"):sub(2))
                if left <= one and (one < right or right == 0) then
                    -- found 1
                    local cp_command = "cp " .. directory .. png_name .. " " .. directory .. "one.png"
                    -- print(cp_command)
                    os.execute(cp_command)
                end
                if left <= two and (two < right or right == 0) then
                    -- found 2
                    local cp_command = "cp " .. directory .. png_name .. " " .. directory .. "two.png"
                    -- print(cp_command)
                    os.execute(cp_command)
                    pfile:close()
                    return
                end
            end
        end
        pfile:close()
    end
end

-- Function to pick two PNG files
local function pick_2_pngs(logs)
    local match = logs.latest_match
    if match ~= nil and match ~= false and match.current_height ~= 0 then
        local span = 1 << (match.current_height - 1)
        local agreed_leaf = 0
        if match.running_leaf ~= nil and bint(match.running_leaf) ~= bint(0) then
            agreed_leaf = bint(match.running_leaf) - 1
        end
        local disagreed_leaf = agreed_leaf + span
        local base = bint(match.tournament.base_big_cycle)
        local step = (bint(1) << match.tournament.log2_stride) >> comp_constants.log2_uarch_span_to_barch
        local agreed_cycle = base + (step * agreed_leaf)
        local disagreed_cycle = base + (step * disagreed_leaf)
        -- print("agreed on mcycle " .. tostring(agreed_cycle) .. " disagreed on " .. tostring(disagreed_cycle))
        copy_png(agreed_cycle, disagreed_cycle)
    end
end

return function(state, logs)
    -- prepare files for frontend
    output_tournaments(state)
    output_hero_claim(logs)
    pick_2_pngs(logs)
end
